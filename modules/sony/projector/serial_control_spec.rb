# encoding: ASCII-8BIT
# frozen_string_literal: true

Orchestrator::Testing.mock_device 'Sony::Projector::SerialControl' do
    exec(:power, false)
    should_send "\xA9\x17\x2F\x00\x00\x00\x3F\x9A"
    wait 100
    should_send "\xA9\x01\x02\x01\x00\x00\x03\x9A"

    transmit "\xA9\x01\x02\x02\x00\x04\xFF\x9A"

    expect(status[:cooling]).to be(true)
    expect(status[:warming]).to be(false)
    expect(status[:power]).to   be(false)
end
