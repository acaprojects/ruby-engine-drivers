# encoding: ASCII-8BIT
# frozen_string_literal: true

Orchestrator::Testing.mock_device 'Zencontrol::Lighting' do
    # Set Group 15 to Arc Level 240 on all controllers
    exec(:light_level, 0x4F, 240)
        .should_send("\x01\xFF\xFF\xFF\xFF\xFF\xFF\x4F\xF0")
end
