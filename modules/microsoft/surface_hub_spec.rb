
Orchestrator::Testing.mock_device 'Microsoft::SurfaceHub' do
    should_send "Power?\n"
    responds "Power=0\n"
    expect(status[:power]).to be(false)

    should_send "Source?\n"
    responds "Source=0\n"
    expect(status[:input]).to be(:pc)

    # Perform actions
    exec(:power, true)
        .should_send("PowerOn\n")
        .responds("Power=1\n")
    expect(status[:power]).to be(true)

    exec(:switch_to, :hdmi)
        .should_send("Source=2\n")
        .responds("Source=2\n")
    expect(status[:input]).to be(:hdmi)
end
