Orchestrator::Testing.mock_device 'Cisco::Switch::SnoopingSg' do
    # Create some mock data
    start_id = "swport-192.168.0.1-gi2"
    mock = Aca::Tracking::SwitchPort.find_by_id(start_id) || Aca::Tracking::SwitchPort.new
    mock.connected('c4544438e158', 5.minutes.to_i, {
        device_ip: '192.168.1.16',
        switch_ip: '192.168.0.1',
        hostname: '',
        switch_name: 'switch259f57',
        interface: 'gi2'
    })

    # Call on_load again to load the above data
    exec(:on_load)

    # Check login works
    transmit "\n\n\nUser Name:"
    should_send "cisco\n"
    transmit "cisco\n"
    transmit "Password:"
    should_send "cisco\n"
    transmit "*****\n"

    transmit 'switch259f57#'
    wait(2500)

    # Should have configured the tracking data above
    mock = Aca::Tracking::SwitchPort.find(start_id)
    expect(mock.nil?).to eq false
    details = status[:gi2]
    expect(details.delete(:connected_at).is_a?(Integer)).to be(true)
    expect(details).to eq({
        ip: "192.168.1.16", mac: "c4544438e158", connected: true,
        clash: false, reserved: false, username: nil, desk_id: nil
    })

    should_send "show interfaces status\n"
    transmit "show interfaces status\n"
    expect(status[:hostname]).to eq('switch259f57')

    transmit <<-ISTATUS
                                             Flow Link          Back   Mdix
Port     Type         Duplex  Speed Neg      ctrl State       Pressure Mode
-------- ------------ ------  ----- -------- ---- ----------- -------- -------
gi1      1G-Copper    Full    1000  Enabled  Off  Up          Disabled On
gi2      1G-Copper      --      --     --     --  Down           --     --
gi3      1G-Copper    Full    1000  Enabled  Off  Up          Disabled On
gi4      1G-Copper    Full    1000  Enabled  Off  Up          Disabled On
gi5      1G-Copper      --      --     --     --  Down           --     --
gi6      1G-Copper      --      --     --     --  Down           --     --
gi7      1G-Copper      --      --     --     --  Down           --     --
gi8      1G-Copper      --      --     --     --  Down           --     --
gi9      1G-Combo-C     --      --     --     --  Down           --     --
gi10     1G-Combo-C     --      --     --     --  Down           --     --

                                          Flow    Link
Ch       Type    Duplex  Speed  Neg      control  State
-------- ------- ------  -----  -------- -------  -----------
Po1         --     --      --      --       --    Not Present
Po2         --     --      --      --       --    Not Present
Po3         --     --      --      --       --    Not Present
Po4         --     --      --      --       --    Not Present
Po5         --     --      --      --       --    Not Present
More: <space>,  Quit: q or CTRL+Z, One line: <return>
ISTATUS

    should_send ' '
    transmit <<-ISTATUS
Po6         --     --      --      --       --    Not Present
Po7         --     --      --      --       --    Not Present
Po8         --     --      --      --       --    Not Present
ISTATUS
    wait(3500)

    # Should have updated this to be offline
    mock = Aca::Tracking::SwitchPort.find(start_id)
    expect(mock.nil?).to eq false
    details = status[:gi2]
    expect(details.delete(:connected_at).is_a?(Integer)).to be(true)
    expect(details).to eq({
        ip: nil, mac: nil, connected: false,
        clash: false, reserved: false, username: nil, desk_id: nil
    })

    should_send "show ip dhcp snooping binding\n"
    transmit <<-SNOOPING
Total number of binding: 2

   MAC Address       IP Address    Lease (sec)     Type    VLAN Interface
------------------ --------------- ------------ ---------- ---- ----------
38:c9:86:17:a2:07  192.168.1.15    159883       learned    1    gi3
c4:54:44:38:e1:58  192.168.1.16    172522       learned    1    gi2
SNOOPING

    # Database writes
    wait(300)

    # Check and delete Database Values
    sp = Aca::Tracking::SwitchPort.find("swport-192.168.0.1-gi3")
    details = sp.details
    expect(details.ip).to eq '192.168.1.15'
    expect(details.mac).to eq '38c98617a207'
    expect(details.connected).to be true
    expect(details.reserved).to be false
    expect(details.clash).to be false

    mock = Aca::Tracking::SwitchPort.find(start_id)
    details = mock.details
    expect(details.ip).to be nil
    expect(details.mac).to be nil
    expect(details.connected).to be false

    sp.destroy
    mock.destroy
end
