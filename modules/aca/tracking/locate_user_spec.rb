Orchestrator::Testing.mock_device 'Aca::Tracking::LocateUser' do
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

    # Check MAC address lookup works
    exec(:lookup, ['192.168.1.16', 'stakach'])
    expect(status['192.168.1.16'.to_sym]).to eq('stakach')
    expect(status['c4544438e158'.to_sym]).to eq('stakach')

    # Ensure database is models are correct
    user = ::Aca::Tracking::UserDevices.for_user('stakach')
    expect(user.macs).to eq(['c4544438e158'])
    expect(user.has?('c4:54:44:38:e1:58')).to be true
    expect(user.class.bucket.get("macuser-c4544438e158")).to eq('stakach')

    macs = ::Aca::Tracking::UserDevices.with_mac('c4:54:44:38:e1:58').to_a
    expect(macs.length).to be(1)
    expect(macs[0].macs).to eq(['c4544438e158'])

    # Ensure remove works
    exec(:logout, '192.168.1.16', 'stakach')
    expect(status['192.168.1.16'.to_sym]).to eq(nil)
    expect(status['c4544438e158'.to_sym]).to eq(nil)

    user = ::Aca::Tracking::UserDevices.for_user('stakach')
    expect(user.macs).to eq([])
    expect(user.class.bucket.get("macuser-c4544438e158", quiet: true)).to be(nil)

    # Test Cleanup
    exec(:lookup, ['192.168.1.16', 'stakach'])
    expect(status['192.168.1.16'.to_sym]).to eq('stakach')
    expect(status['c4544438e158'.to_sym]).to eq('stakach')
    expect(user.class.bucket.get("macuser-c4544438e158")).to eq('stakach')

    # Ensure model cleans itself up
    ::Aca::Tracking::UserDevices.for_user('stakach').destroy
    expect(user.class.bucket.get("macuser-c4544438e158", quiet: true)).to be(nil)
    mock.destroy
end
