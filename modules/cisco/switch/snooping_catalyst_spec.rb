Orchestrator::Testing.mock_device 'Cisco::Switch::SnoopingCatalyst' do
    # Create some mock data
    start_id = "swport-192.168.0.1-gi4/1/2"
    mock = Aca::Tracking::SwitchPort.find_by_id(start_id) || Aca::Tracking::SwitchPort.new
    mock.connected('c4544438e158', 5.minutes.to_i, {
        device_ip: '192.168.1.16',
        switch_ip: '192.168.0.1',
        hostname: '',
        switch_name: 'SG-MARWFA61301',
        interface: 'gi4/1/2'
    })

    # Call on_load again to load the above data
    exec(:on_load)
    transmit 'SG-MARWFA61301>'
    wait(1500)

    # Should have configured the tracking data above
    mock = Aca::Tracking::SwitchPort.find(start_id)
    expect(mock.nil?).to eq false
    details = status[:"Gi4/1/2"]
    expect(details.delete(:connected_at).is_a?(Integer)).to be(true)
    expect(details).to eq({
        ip: "192.168.1.16", mac: "c4544438e158", connected: true,
        clash: false, reserved: false, username: nil, desk_id: nil
    })

    should_send "show interfaces status\n"
    transmit "show interfaces status\n"
    expect(status[:hostname]).to eq('SG-MARWFA61301')

    transmit <<-ISTATUS
Port      Name               Status       Vlan       Duplex  Speed Type 
Gi1/0/1                      notconnect   113          auto   auto 10/100/1000BaseTX
Gi1/0/2                      notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/11                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/12                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/13                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/14                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/15                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/16                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/17                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/18                     notconnect   113          auto   auto 10/100/1000BaseTX
 --More-- 
ISTATUS

    should_send ' '
    transmit <<-ISTATUS
Gi4/0/48                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi4/1/1                      notconnect   1            auto   auto unknown
Gi4/1/2                      notconnect   1            auto   auto unknown
Te4/1/4                      connected    trunk        full    10G SFP-10GBase-SR
Po1                          connected    trunk      a-full  a-10G
ISTATUS
    wait(3500)

    # Should have updated this to be offline
    mock = Aca::Tracking::SwitchPort.find(start_id)
    expect(mock.nil?).to be false
    details = status[:"gi4/1/2"]
    expect(details.delete(:connected_at).is_a?(Integer)).to be(true)
    expect(details).to eq({
        ip: nil, mac: nil, connected: false,
        clash: false, reserved: false, username: nil, desk_id: nil
    })

    should_send "show ip dhcp snooping binding\n"
    transmit <<-SNOOPING
MacAddress          IpAddress        Lease(sec)  Type           VLAN  Interface
------------------  ---------------  ----------  -------------  ----  --------------------
38:C9:86:17:A2:07   192.168.1.15     19868       dhcp-snooping   113   tenGigabitEthernet4/1/4
C8:5B:76:08:F4:FA   10.151.128.150   16532       dhcp-snooping   113   GigabitEthernet3/0/43
00:21:CC:D5:33:F4   10.151.130.1     16283       dhcp-snooping   113   GigabitEthernet3/0/43
Total number of bindings: 3

SNOOPING

    # Database writes
    wait(300)

    # Check and delete Database Values
    sp = Aca::Tracking::SwitchPort.find("swport-192.168.0.1-te4/1/4")
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
