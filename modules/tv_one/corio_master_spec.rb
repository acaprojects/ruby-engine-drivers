Orchestrator::Testing.mock_device 'TvOne::CorioMaster',
                                  settings: {
                                      username: 'admin',
                                      password: 'adminpw'
                                  } do
    # Util to clear out any state_sync queries
    def sync_state
        should_send "Preset.Take\r\n"
        responds <<~RX
            Preset.Take = 1\r
            !Done Preset.Take\r
        RX
        should_send "Routing.Preset.PresetList()\r\n"
        responds <<~RX
            !Done Routing.Preset.PresetList()\r
        RX
        should_send "Windows\r\n"
        responds <<~RX
            !Done Windows\r
        RX
        should_send "Canvases\r\n"
        responds <<~RX
            !Done Canvases\r
        RX
        should_send "Layouts\r\n"
        responds <<~RX
            !Done Layouts\r
        RX
    end

    transmit <<~INIT
        // ===================\r
        //  CORIOmaster - CORIOmax\r
        // ===================\r
        // Command Interface Ready\r
        Please login. Use 'login(username,password)'\r
    INIT

    should_send "login(admin,adminpw)\r\n"
    responds "!Info : User admin Logged In\r\n"
    expect(status[:connected]).to be(true)

    sync_state

    should_send "CORIOmax.Serial_Number\r\n"
    responds <<~RX
        CORIOmax.Serial_Number = 2218031005149\r
        !Done CORIOmax.Serial_Number\r
    RX
    expect(status[:serial_number]).to be(2218031005149)

    should_send "CORIOmax.Software_Version\r\n"
    responds <<~RX
        CORIOmax.Software_Version = V1.30701.P4 Master\r
        !Done CORIOmax.Software_Version\r
    RX
    expect(status[:firmware]).to eq('V1.30701.P4 Master')


    exec(:exec, 'System.Reset')
        .should_send("System.Reset()\r\n")
        .responds <<~RX
            !Info: Rebooting...\r
        RX
    expect(result).to eq('Rebooting...')

    exec(:set, 'Window1.Input', 'Slot3.In1')
        .should_send("Window1.Input = Slot3.In1\r\n")
        .responds <<~RX
            Window1.Input = Slot3.In1\r
            !Done Window1.Input\r
        RX
    expect(result).to eq('Slot3.In1')

    exec(:query, 'Window1.Input', expose_as: :status_var_test)
        .should_send("Window1.Input\r\n")
        .responds <<~RX
            Window1.Input = Slot3.In1\r
            !Done Window1.Input\r
        RX
    expect(result).to eq('Slot3.In1')
    expect(status[:status_var_test]).to eq('Slot3.In1')

    exec(:deep_query, 'Windows')
        .should_send("Windows\r\n")
        .responds(
            <<~RX
                Windows.Window1 = <...>\r
                Windows.Window2 = <...>\r
                !Done Windows\r
            RX
        )
        .should_send("window1\r\n")
        .responds(
            <<~RX
                Window1.FullName = Window1\r
                Window1.Alias = NULL\r
                Window1.Input = Slot3.In1\r
                Window1.Canvas = Canvas1\r
                Window1.CanWidth = 1280\r
                Window1.CanHeight = 720\r
                !Done Window1\r
            RX
        )
        .should_send("window2\r\n")
        .responds(
            <<~RX
                Window2.FullName = Window2\r
                Window2.Alias = NULL\r
                Window2.Input = Slot3.In2\r
                Window2.Canvas = Canvas1\r
                Window2.CanWidth = 1280\r
                Window2.CanHeight = 720\r
                !Done Window2\r
            RX
        )
    expect(result).to eq(
        window1: {
            fullname: 'Window1',
            alias: nil,
            input: 'Slot3.In1',
            canvas: 'Canvas1',
            canwidth: 1280,
            canheight: 720
        },
        window2: {
            fullname: 'Window2',
            alias: nil,
            input: 'Slot3.In2',
            canvas: 'Canvas1',
            canwidth: 1280,
            canheight: 720
        }
    )

    exec(:query_preset_list)
        .should_send("Routing.Preset.PresetList()\r\n")
        .responds(
            <<~RX
                Routing.Preset.PresetList[1]=Sharing-Standard,Canvas1,0\r
                Routing.Preset.PresetList[2]=Standard-4-Screen,Canvas1,0\r
                Routing.Preset.PresetList[3]=Standard-10-Screen,Canvas1,0\r
                Routing.Preset.PresetList[11]=Clear,Canvas1,0\r
                !Done Routing.Preset.PresetList()\r
            RX
        )
    expect(result).to eq(
        1  => { name: 'Sharing-Standard',   canvas: 'Canvas1', time: 0 },
        2  => { name: 'Standard-4-Screen',  canvas: 'Canvas1', time: 0 },
        3  => { name: 'Standard-10-Screen', canvas: 'Canvas1', time: 0 },
        11 => { name: 'Clear',              canvas: 'Canvas1', time: 0 }
    )


    exec(:preset, 1)
        .should_send("Preset.Take = 1\r\n")
        .responds(
            <<~RX
                Preset.Take = 1\r
                !Done Preset.Take\r
            RX
        )
    wait_tick
    sync_state
    expect(status[:preset]).to be(1)

    exec(:switch, 'Slot1.In1' => 1, 'Slot1.In2' => 2)
        .should_send("Window1.Input = Slot1.In1\r\n")
        .responds(
            <<~RX
                Window1.Input = Slot1.In1\r
                !Done Window1.Input\r
            RX
        )
        .should_send("Window2.Input = Slot1.In2\r\n")
        .responds(
            <<~RX
                Window2.Input = Slot1.In2\r
                !Done Window2.Input\r
            RX
        )
    wait_tick
    expect(status[:windows][:window1][:input]).to eq('Slot1.In1')
    expect(status[:windows][:window2][:input]).to eq('Slot1.In2')
end
