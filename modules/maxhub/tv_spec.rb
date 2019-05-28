# encoding: ASCII-8BIT
# frozen_string_literal: true

Orchestrator::Testing.mock_device 'Maxhub::Tv' do
    exec(:power?)
        .should_send("\xAA\xBB\xCC\x01\x02\x00\x03\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x80\x01\x00\x81\xDD\xEE\xFF")
        .expect(status[:power]).to be(false)

    wait(2000)

    exec(:power, true)
        .should_send("\xAA\xBB\xCC\x01\x00\x00\x01\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x80\x00\x00\x80\xDD\xEE\xFF")
        .expect(status[:power]).to be(true)

    exec(:input?)
        .should_send("\xAA\xBB\xCC\x02\x00\x00\x02\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x81\x05\x00\x86\xDD\xEE\xFF")
        .expect(status[:input]).to be("hdmi3")

    exec(:switch_to, "pc")
        .should_send("\xAA\xBB\xCC\x02\x08\x00\x0A\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x81\x08\x00\x89\xDD\xEE\xFF")
        .expect(status[:input]).to be("pc")

    exec(:mute?)
        .should_send("\xAA\xBB\xCC\x03\x03\x00\x06\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x82\x01\x01\x84\xDD\xEE\xFF")
        .expect(status[:mute]).to be(false)

    exec(:mute_audio)
        .should_send("\xAA\xBB\xCC\x03\x01\x00\x04\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x82\x01\x00\x83\xDD\xEE\xFF")
        .expect(status[:mute]).to be(true)

    exec(:unmute_audio)
        .should_send("\xAA\xBB\xCC\x03\x01\x01\x05\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x82\x01\x01\x84\xDD\xEE\xFF")
        .expect(status[:mute]).to be(false)

    exec(:volume?)
        .should_send("\xAA\xBB\xCC\x03\x02\x00\x05\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x82\x00\x06\x09\xDD\xEE\xFF")
        .expect(status[:volume]).to be(6)

    exec(:volume, 99)
        .should_send("\xAA\xBB\xCC\x03\x00\x63\x00\xDD\xEE\xFF")
        .responds("\xAA\xBB\xCC\x82\x00\x63\x00\xDD\xEE\xFF")
        .expect(status[:volume]).to be(99)
end
