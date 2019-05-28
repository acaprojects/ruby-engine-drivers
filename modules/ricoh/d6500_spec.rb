# encoding: ASCII-8BIT
# frozen_string_literal: true

Orchestrator::Testing.mock_device 'Ricoh::D6500' do
    exec(:power, true)
        .should_send("\x38\x30\x32\x73\x21\x30\x30\x31\x0D") # power on
        .responds("\x34\x30\x32\x2B\x0D")
        .expect(status[:power]).to be(true)

    exec(:power?)
        .should_send("\x38\x30\x32\x67\x6C\x30\x30\x30\x0D") # power query
        .responds("\x38\x30\x32\x72\x6C\x30\x30\x30\x0D")
        .expect(status[:power]).to be(false)

    exec(:input?)
        .should_send("\x38\x30\x32\x67\x6A\x30\x30\x30\r") # input query
        .responds("\x38\x30\x32\x72\x6A\x30\x30\x31\x0D")
        .expect(status[:input]).to eq(:hdmi)

    exec(:switch_to, 'dvi')
        .should_send("\x38\x30\x32\x73\x22\x30\x30\x36\x0D")
        .responds("\x34\x30\x32\x2B\x0D")
        .expect(status[:input]).to eq(:dvi)
end
