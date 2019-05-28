# encoding: ASCII-8BIT

Orchestrator::Testing.mock_device 'Pjlink::Pjlink' do
    exec(:power?)
        .should_send("%1POWR ?\x0D")
        .responds("%1POWR=1\x0D")
    expect(status[:power]).to be(true)

    exec(:power, true)
        .should_send("%1POWR 1\x0D")
        .responds("%1POWR=OK\x0D")
    expect(status[:power]).to be(true)

    exec(:power, false)
        .should_send("%1POWR 0\x0D")
        .responds("%1POWR=OK\x0D")
    expect(status[:power]).to be(false)

    exec(:input?)
        .should_send("%1INPT ?\x0D")
        .responds("%1INPT=31\x0D")
    expect(status[:input]).to be(:hdmi)

    exec(:switch_to, :hdmi)
        .should_send("%1INPT 31\x0D")
        .responds("%1INPT=OK\x0D")
    expect(status[:input]).to be(:hdmi)

    exec(:switch_to, :hdmi2)
        .should_send("%1INPT 32\x0D")
        .responds("%1INPT=OK\x0D")
    expect(status[:input]).to be(:hdmi2)

    exec(:switch_to, :hdmi3)
        .should_send("%1INPT 33\x0D")
        .responds("%1INPT=OK\x0D")
    expect(status[:input]).to be(:hdmi3)

    exec(:switch_to, :rgb)
        .should_send("%1INPT 11\x0D")
        .responds("%1INPT=OK\x0D")
    expect(status[:input]).to be(:rgb)

    exec(:switch_to, :storage)
        .should_send("%1INPT 41\x0D")
        .responds("%1INPT=OK\x0D")
    expect(status[:input]).to be(:storage)

    exec(:switch_to, :network)
        .should_send("%1INPT 51\x0D")
        .responds("%1INPT=OK\x0D")
    expect(status[:input]).to be(:network)

    exec(:mute?)
        .should_send("%1AVMT ?\x0D")
        .responds("%AVMT=30\x0D")
    expect(status[:mute]).to be(false)

    exec(:mute, false)
        .should_send("%1AVMT 30\x0D")
        .responds("%AVMT=OK\x0D")
    expect(status[:mute]).to be(false)

    exec(:mute, true)
        .should_send("%1AVMT 31\x0D")
        .responds("%AVMT=OK\x0D")
    expect(status[:mute]).to be(true)

    exec(:video_mute, false)
        .should_send("%1AVMT 10\x0D")
        .responds("%AVMT=OK\x0D")
    expect(status[:video_mute]).to be(false)

    exec(:video_mute, true)
        .should_send("%1AVMT 11\x0D")
        .responds("%AVMT=OK\x0D")
    expect(status[:video_mute]).to be(true)

    exec(:audio_mute, false)
        .should_send("%1AVMT 20\x0D")
        .responds("%AVMT=OK\x0D")
    expect(status[:audio_mute]).to be(false)

    exec(:audio_mute, true)
        .should_send("%1AVMT 21\x0D")
        .responds("%AVMT=OK\x0D")
    expect(status[:audio_mute]).to be(true)

    exec(:error_status?)
        .should_send("%1ERST ?\x0D")
        .responds("%ERST=000000\x0D")
    expect(status[:errors]).to be(nil)

    exec(:lamp?)
        .should_send("%1LAMP ?\x0D")
        .responds("%LAMP=12345 1\x0D")
    expect(status[:lamp_hours]).to be(12345)

    exec(:name?)
        .should_send("%1NAME ?\x0D")
        .responds("%NAME=Test Projector\x0D")
    expect(status[:name]).to be("Test Projector")
end
