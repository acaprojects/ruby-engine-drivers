Orchestrator::Testing.mock_device 'Shure::Mixer::P300' do
    exec(:trigger?)
        .should_send("< GET PRESET >")
        .responds("< REP PRESET 06 >")
        .expect(status[:preset]).to be(6)

    exec(:trigger, 8)
        .should_send("< SET PRESET 8 >")
        .responds("< REP PRESET 8 >")
        .expect(status[:preset]).to be(8)

    exec(:flash_leds)
        .should_send("< SET FLASH ON >")
        .responds("< REP FLASH ON >")

    exec(:fader?, 0)
        .should_send("< GET 00 AUDIO_GAIN_HI_RES >")
        .responds("< REP 00 AUDIO_GAIN_HI_RES 0022 >")
        .expect(status[:channel0_gain]).to be(22)

    exec(:fader?, [1,2,3])
        .should_send("< GET 01 AUDIO_GAIN_HI_RES >")
        .responds("< REP 01 AUDIO_GAIN_HI_RES 0001 >")
        .should_send("< GET 02 AUDIO_GAIN_HI_RES >")
        .responds("< REP 02 AUDIO_GAIN_HI_RES 1111 >")
        .should_send("< GET 03 AUDIO_GAIN_HI_RES >")
        .responds("< REP 03 AUDIO_GAIN_HI_RES 0321 >")

    exec(:fader, [1,2,3], 39)
        .should_send("< SET 01 AUDIO_GAIN_HI_RES 0039 >")
        .responds("< REP 01 AUDIO_GAIN_HI_RES 0039 >")
        .should_send("< SET 02 AUDIO_GAIN_HI_RES 0039 >")
        .responds("< REP 02 AUDIO_GAIN_HI_RES 0039 >")
        .should_send("< SET 03 AUDIO_GAIN_HI_RES 0039 >")
        .responds("< REP 03 AUDIO_GAIN_HI_RES 0039 >")

    exec(:mute?, 10)
        .should_send("< GET 10 AUDIO_MUTE >")
        .responds("< REP 10 AUDIO_MUTE OFF >")
        .expect(status[:channel10_mute]).to be(false)

    exec(:mute, [1,2,3])
        .should_send("< SET 01 AUDIO_MUTE ON >")
        .responds("< REP 01 AUDIO_MUTE ON >")
        .should_send("< SET 02 AUDIO_MUTE ON >")
        .responds("< REP 02 AUDIO_MUTE ON >")
        .should_send("< SET 03 AUDIO_MUTE ON >")
        .responds("< REP 03 AUDIO_MUTE ON >")

    exec(:error?)
        .should_send("< GET LAST_ERROR_EVENT >")
        .responds("< REP LAST_ERROR_EVENT this is a sample error >")
        .expect(status[:error]).to eq("this is a sample error")
end
