# encoding: ASCII-8BIT

Orchestrator::Testing.mock_device 'Sony::Display::Bravia' do
    exec(:power, true)
        .should_send("\x2A\x53\x43POWR0000000000000001\n")
        .responds("\x2A\x53\x41POWR0000000000000000\n")
        .should_send("\x2A\x53\x45POWR################\n")
        .responds("\x2A\x53\x41POWR0000000000000001\n")
    expect(status[:power]).to be(true)

    exec(:switch_to, :hdmi)
        .should_send("\x2A\x53\x43INPT0000000100000001\n")
        .responds("\x2A\x53\x41INPT0000000000000000\n")
        .should_send("\x2A\x53\x45INPT################\n")
        .responds("\x2A\x53\x41INPT0000000100000001\n")
    expect(status[:input]).to be(:hdmi)

    exec(:switch_to, :vga34)
        .should_send("\x2A\x53\x43INPT0000000600000034\n")
        .responds("\x2A\x53\x41INPT0000000000000000\n")
        .should_send("\x2A\x53\x45INPT################\n")
        .responds("\x2A\x53\x41INPT0000000600000034\n")
    expect(status[:input]).to be(:vga34)

    exec(:volume, 99)
        .should_send("\x2A\x53\x43VOLU0000000000000099\n")
        .responds("\x2A\x53\x41VOLU0000000000000000\n")
        .should_send("\x2A\x53\x45VOLU################\n")
        .responds("\x2A\x53\x41VOLU0000000000000099\n")
    expect(status[:volume]).to be(99)

    exec(:mute)
        .should_send("\x2A\x53\x43PMUT0000000000000001\n")
        .responds("\x2A\x53\x41PMUT0000000000000000\n")
        .should_send("\x2A\x53\x45PMUT################\n")
        .responds("\x2A\x53\x41PMUT0000000000000001\n")
    expect(status[:mute]).to be(true)

    # Test failure
    exec(:unmute)
        .should_send("\x2A\x53\x43PMUT0000000000000000\n")
        .responds("\x2A\x53\x41PMUTFFFFFFFFFFFFFFFF\n")
        .should_send("\x2A\x53\x45PMUT################\n")
        .responds("\x2A\x53\x41PMUT0000000000000001\n")
    expect(status[:mute]).to be(true)

    # Test notify
    exec(:volume, 50)
        .should_send("\x2A\x53\x43VOLU0000000000000050\n")
        .responds("\x2A\x53\x4EPMUT0000000000000000\n") # mix in a notify
        .responds("\x2A\x53\x41VOLU0000000000000000\n")
        .should_send("\x2A\x53\x45VOLU################\n")
        .responds("\x2A\x53\x41VOLU0000000000000050\n")
    expect(status[:volume]).to be(50)
    expect(status[:mute]).to be(false)
end
