# Description:
#   A Hubot script for interacting with Phabricator
#
# Dependencies:
#   "canduit": "^1.1.2"
#   "lodash"
#
# Configuration:
#   HUBOT_PHABRICATOR_API="https://phabricator.com/api/"
#   HUBOT_PHABRICATOR_TOKEN="api-abcdef11235813"
#
# Commands:
#   hubot phabricator my <any|open|closed|accepted> diffs - Displays reviews which has you as responsible user (max: 10)
#   hubot phabricator whoami - Displays your linked Phabricator username guessed based on email
#   hubot phabricator i am <username> - Sets your linked Phabricator username
#   hubot phabricator ping - Pings Phabricator's API
#   phabricator subscribe - Subscribes to important actions (**use only in DM**)
#   phabricator unsubscribe - Unsubscribes from important actions (**use only in DM**)
#   D#### - Linkify differential code review (case-sensitive)

_ = require 'lodash'
createCanduit = require 'canduit'


DEBUG_ROOM = process.env.HUBOT_PHABRICATOR_DEBUG_ROOM or 'general'
DEBUG = process.env.NODE_ENV == 'development'

POLL_INTERVAL_MS = 30000

config = {
  api: process.env.HUBOT_PHABRICATOR_API
  token: process.env.HUBOT_PHABRICATOR_TOKEN
}

keyPHID = (userId) -> 'pha__phid_'+userId
keyUser = (phid) -> 'pha__user_'+phid
keySubIgnore = 'pha__sub_ignore'
keySubLast = 'pha__sub_last'

STATUS =
  NEEDS_REVIEW: '0'
  NEEDS_REVISION: '1'
  ACCEPTED: '2'
  CLOSED: '3'
  ABANDONED: '4'
  CHANGES_PLANNED: '5'

modifiedAfter = (lastChecked, value) ->
  value.dateModified >= lastChecked

replyToAnon = (res) ->
  res.reply "phabricator doesn't know you"
  res.reply 'try specifing your name with "phabricator i am <USERNAME>"'

iconForStatus = (status) ->
  switch status
    when STATUS.NEEDS_REVIEW
      ':needs_review:'
    when STATUS.NEEDS_REVISION
      ':needs_revision:'
    when STATUS.ACCEPTED
      ':accepted:'
    when STATUS.CLOSED
      ':closed:'
    when STATUS.ABANDONED
      ':abandoned:'
    when STATUS.CHANGES_PLANNED
      ':changes_planned:'


module.exports = (robot) ->
  for key, value of config
    if not value
      robot.logger.error "phabricator missing config: #{key}"
      robot.messageRoom DEBUG_ROOM, "phabricator missing config: #{key}"
      return

  conduit = createCanduit config,
    (error, conduit) ->

  formatDiffVerbose = (diff) ->
    icon = iconForStatus(diff.status)
    author = userForPHID(diff.authorPHID)
    author_name = author.real_name or author.name
    if author.id
      author_stripped = author.name.replace('.', '')
      emoji = ":#{author_stripped}: "
    else
      emoji = ""

    "#{icon} #{diff.uri} - #{emoji}#{author_name}\n\t\t\t#{diff.title}"
      .replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')

  userForPHID = (phid) ->
    uid = robot.brain.get keyUser(phid)
    if not uid
      robot.logger.info "No user found for #{phid}: phetching data"
      matchUserPhid phid
      return {
        name: phid
        real_name: phid
      }

    robot.brain.userForId(uid)

  matchUserPhid = (phid) ->
    names = [phid]
    conduit.exec 'phid.lookup', {names}, (err, result) ->
      if err
        robot.logger.error "Error fetching phid.lookup #{phid}: #{err}"
        return

      if result[phid]?
        phab_name = result[phid]['name']
        robot.logger.info "phid.lookup: #{phid} is user: #{phab_name}"
        matches = (user for user_id, user of robot.brain.data.users when (user.email_address? and (user.email_address.indexOf(phab_name)== 0)))
        if matches.length == 1
          robot.logger.info "Mapping #{phid}/#{phab_name} to #{matches[0].id}/#{matches[0].name}"
          robot.brain.set keyPHID(matches[0].id), phid
          robot.brain.set keyUser(phid), matches[0].id
        else
          robot.logger.info "Couldn't match #{phid}/#{phab_name}, found #{matches}"

  replyWithPHID = (robot, userId, possibleUsername) ->
    phid = robot.brain.get keyPHID(userId)

    if phid? and not possibleUsername?
      (callback) -> callback phid
    else
      (callback) ->
        usernames = if possibleUsername?
          [possibleUsername]
        else
          user = robot.brain.userForId userId
          [
            user.email_address.replace(/@.*/i, '').replace(/\./i, '')
          ]

        conduit.exec 'user.query', {usernames: usernames}, (err, result) ->
          if result.length
            phid = result[0].phid
            robot.brain.set keyPHID(userId), phid
            robot.brain.set keyUser(phid), userId

            callback phid
          else
            callback null


  robot.respond /phab(ricator)? whoami/i, (res) ->
    userId = res.message.user.id
    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon res
        return

      names = [phid]

      conduit.exec 'phid.lookup', {names}, (err, result) ->
        if err
          res.reply err
          return

        if result[phid]?
          res.reply 'you are ' + result[phid].name
        else
          robot.brain.remove keyPHID(userId)
          robot.brain.remove keyUser(phid)
          replyToAnon res

  robot.respond /phab(ricator)? i('m| am) ([a-zA-Z0-9._-]+)/i, (res) ->
    userId = res.message.user.id
    replyWithPHID(robot, userId, res.match[3]) (phid) ->
      if phid?
        robot.brain.set keyPHID(userId), phid
        robot.brain.set keyUser(phid), userId
        res.reply "I will remember your phid, which is `#{ phid }`"

      else
        res.reply "phabricator doesn't know this name"

  robot.respond /phab(ricator)? ping/i, (res) ->
    conduit.exec 'conduit.ping', null, (err, result) ->
      if err
        res.reply "ERR: " + err
        return

      res.reply result

  robot.respond /phab(ricator)? my (any|open|closed|accepted)? ?(diff|review)s?/i, (res) ->
    userId = res.message.user.id

    robot.logger.info "Fetching reviews for #{userId}"

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon res
        return

      statusName = res.match[2] or 'open'

      status = 'status-' + statusName
      responsibleUsers = [phid]
      query = _.assign {status, responsibleUsers}, {
        order: 'order-modified'
        limit: 10
      }

      conduit.exec 'differential.query', query, (err, result) ->
        if err
          robot.logger.error "Error fetching reviews for #{userId}: #{err}"
          res.reply err
          return

        diffsList = _.map(result, formatDiffVerbose)

        res.reply(
          'you have ' + _.keys(result).length + ' ' + statusName + ' diffs\n' +
          diffsList.join('\n')
        )

  subIntervalId = setInterval(
    ->
      query = {
        order: 'order-modified'
        limit: 10
      }

      conduit.exec 'differential.query', query, (err, result) ->
        if err
          robot.logger.error "phabricator subscription error: #{err}"
          robot.messageRoom DEBUG_ROOM, "phabricator subscription error: #{err}"
          clearInterval subIntervalId
          return

        if robot.brain.get keySubLast
          lastChecked = robot.brain.get keySubLast
          result = _.filter(
            result,
            modifiedAfter.bind null, lastChecked
          )

        robot.brain.set keySubLast, parseInt(Date.now() / 1000, 10)

        unless result.length
          return

        for review in result
          notifyUsers = switch review.status
            when STATUS.NEEDS_REVIEW
              _(review.reviewers)
            when STATUS.NEEDS_REVISION
              _([review.authorPHID])
            when STATUS.ACCEPTED
              _([review.authorPHID])
            when STATUS.CLOSED
              _()
            when STATUS.ABANDONED
              _()
            when STATUS.CHANGES_PLANNED
              _()

          msgText = formatDiffVerbose(review)
          notifyUsers
            .reject(_.includes.bind(null, robot.brain.get keySubIgnore))
            .map(keyUser)
            .map(robot.brain.get.bind(robot.brain))
            .filter()
            .map(robot.brain.userForId.bind(robot.brain))
            .filter()
            .map('name')
            .forEach((username) ->
              if DEBUG
                robot.logger.debug username, msgText
              else
                robot.messageRoom username, msgText
            )
    POLL_INTERVAL_MS
  )

  robot.respond /phab(ricator)? unsub(scribe)?/i, (res) ->
    userId = res.message.user.id

    if res.message.room != res.message.user.name
      res.reply 'deal with subscription in private'

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon res
        return

      ignoreList = robot.brain.get(keySubIgnore) or []
      if phid in ignoreList
        res.reply 'you\'ve already been unsubscribed from phabricator notifications'
      else
        ignoreList.push phid
        robot.brain.set keySubIgnore, ignoreList

        res.reply 'you\'ve been unsubscribed from phabricator notifications'

  robot.respond /phab(ricator)? sub(scribe)?/i, (res) ->
    userId = res.message.user.id

    if res.message.room != res.message.user.name
      res.reply 'deal with subscription in private'

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon res
        return

      ignoreList = robot.brain.get(keySubIgnore) or []
      if phid in ignoreList
        ignoreList = _.without ignoreList, phid
        robot.brain.set keySubIgnore, ignoreList

      res.reply 'you\'ve been subscribed to phabricator notifications'

  # ## Linkify differential code review (case-sensitive)
  #
  # Inspiration:
  # https://github.com/kemayo/hubot-phabricator/blob/master/src/phabricator.coffee
  robot.hear /\b(D[0-9]+)\b/g, (res) ->
    names = (match.trim() for match in res.match when match.trim())
    if names.length == 0
      return

    ids = (parseInt(name.substr(1), 10) for name in names)

    conduit.exec 'differential.query', {ids: ids}, (err, result) ->
      if err
        robot.logger.error "differential.query failed: #{err}"
        return

      text = (":point_up_2: #{formatDiffVerbose(diff)}" for diff in result).join('\n')
      if text
        res.send text
