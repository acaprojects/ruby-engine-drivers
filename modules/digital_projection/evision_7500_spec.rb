Orchestrator::Testing.mock_device 'DigitalProjection::Evision_7500' do
    exec(:power?)
        .should_send("*power ?\r") # power query
        .responds("ack power = 0\r") # respond with off
        .expect(status[:power]).to be(false)

    exec(:power, true)
        .should_send("*power = 1\r") # power query
        .responds("ack power = 1\r") # respond with on
        .expect(status[:power]).to be(true)

    exec(:input?)
        .should_send("*input ?\r")
        .responds("ack input = 0\r") # respond with on
        .expect(status[:input]).to be(:display_port)

    exec(:switch_to, "hdmi")
        .should_send("*input = 1\r")
        .responds("ack input = 1\r") # respond with on
        .expect(status[:input]).to be(:hdmi)

    exec(:freeze?)
        .should_send("*freeze ?\r") # power query
        .responds("ack freeze = 0\r") # respond with on
        .expect(status[:freeze]).to be(false)

    exec(:freeze, true)
        .should_send("*freeze = 1\r") # power query
        .responds("ack power = 1\r") # respond with on
        .expect(status[:freeze]).to be(true)

    exec(:laser?)
        .should_send("*laser.hours ?\r")
        .responds("ack laser.hours = 1000\r")
        .expect(status[:laser]).to be(1000)

    exec(:laser_reset)
        .should_send("*laser.reset\r")
        .responds("ack laser.reset\r") # this is suppose to respond with a check mark
        .expect(status[:laser]).to be(0)

    exec(:error?)
        .should_send("*errcode\r")
        .responds("ack errorcode = this is a sample error code\r")
        .expect(status[:error]).to eq("this is a sample error code")
end
