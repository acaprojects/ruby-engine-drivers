# encoding: ASCII-8BIT
# frozen_string_literal: true

Orchestrator::Testing.mock_device 'Helvar::Net' do
    # Perform actions
    exec(:trigger, 1, 2, 1100)
        .should_send('>V:2,C:11,G:1,S:2,F:110#')
        .responds('>V:2,C:11,G:1,S:2,F:110,A:1#')
    expect(status[:area1]).to be(2)

    exec(:get_current_preset, 17)
        .should_send('>V:2,C:109,G:17#')
        .responds('?V:2,C:109,G:17=14#')
    expect(status[:area17]).to be(14)

    exec(:get_current_preset, 20)
        .should_send('>V:2,C:109,G:20#')
        .responds('!V:2,C:109,G:20=1#')
    expect(status[:last_error]).to eq('error Invalid group index parameter for !V:2,C:109,G:20=1')
end
