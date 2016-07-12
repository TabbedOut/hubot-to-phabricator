Helper = require('hubot-test-helper')
chai = require 'chai'

expect = chai.expect

helper = new Helper('../src/to-phabricator.coffee')

describe 'to-phabricator', ->
  beforeEach ->
    @room = helper.createRoom()

  afterEach ->
    @room.destroy()

  # FIXME this test is just to document an example test
  it 'needs to be configured', ->
    @room.user.say('alice', '@hubot ping').then =>
      expect(@room.messages).to.eql [
        ['hubot', 'phabricator missing config: api']
        ['alice', '@hubot ping']
      ]
