# encoding: ASCII-8BIT
# frozen_string_literal: true

Orchestrator::Testing.mock_device 'Ricoh::PJ_WXL4540' do
    exec(:power?)
        .should_send("#SPS\x0D")
        .responds("=SPS:0\x0D")
        .expect(status[:power]).to be(false)

    exec(:power, true)
        .should_send("#PON\x0D") # power on
        .responds("=PON:SC0\x0D") # not sure if this response is correct
        .expect(status[:power]).to be(true)

    exec(:power?)
        .should_send("#SPS\x0D")
        .responds("=SPS:5\x0D")
        .expect(status[:power]).to be(true)

    exec(:input?)
        .should_send("#SIS\x0D")
        .responds("=SIS:9\x0D")
        .expect(status[:input]).to eq(:video)

    exec(:switch_to, 'hdmi')
        .should_send("#INP:6\x0D") # input query
        .responds("=INP:6\x0D")
        .expect(status[:input]).to eq(:hdmi)

    exec(:preset, 'pc')
        .should_send("#PIC:1\x0D")
        .responds("=PIC:1\x0D")
        .expect(status[:preset]).to eq(:pc)

    exec(:error?)
        .should_send("#SER\x0D")
        .responds("=SER:16\x0D")
        .expect(status[:error]).to eq('Color Wheel (Phospher wheel)')
end
