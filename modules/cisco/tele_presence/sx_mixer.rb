load File.expand_path('./sx_telnet.rb', File.dirname(__FILE__))
load File.expand_path('./sx_mixer_common.rb', File.dirname(__FILE__))


class Cisco::TelePresence::SxMixer < Cisco::TelePresence::SxTelnet
    include Cisco::TelePresence::SxMixerCommon

    # Communication settings
    tokenize delimiter: "\r",
             wait_ready: "login:"
    clear_queue_on_disconnect!

    descriptive_name 'Cisco TelePresence Mixer'
    generic_name :Mixer
end
