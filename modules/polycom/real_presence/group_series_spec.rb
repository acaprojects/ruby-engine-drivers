Orchestrator::Testing.mock_device 'Polycom::RealPresence::GroupSeries' do
    # Check login works
    transmit "\n\n\nPassword:"
    should_send "\r"

    transmit "Serial Number: 12345\r\n"
    expect(status[:serial]).to eq('12345')

    wait(250)
end
