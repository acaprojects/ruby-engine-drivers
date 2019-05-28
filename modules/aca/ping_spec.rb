# frozen_string_literal: true
# encoding: ASCII-8BIT

Orchestrator::Testing.mock_device 'Aca::Ping', ip: 'localhost' do
    exec(:ping_device)
    expect(result).to be(true)
    expect(status[:connected]).to be(true)
end
