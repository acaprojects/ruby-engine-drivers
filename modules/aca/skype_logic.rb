module Aca; end

class Aca::SkypeLogic
    include ::Orchestrator::Constants

    descriptive_name 'ACA Skype Logic'
    generic_name :Skype
    implements :logic


    def on_load
        self[:accept_call] = 0
        self[:hang_up] = 0
        self[:call_uri] = 0
        self[:open_dev_tools] = 0
        self[:clear_local_storage] = 0

        @mic_mutes = setting(:mics_mutes)
    end


    def set_uri(uri)
        if uri.present?
            self[:uri] = uri
        else
            self[:uri] = nil
        end
    end

    def call_uri(uri = nil)
        #set_uri(uri)
        return unless self[:uri].present?
        self[:call_uri] += 1
    end

    def incoming_call(state, remote = nil)
        self[:incoming_call] = !!state
        self[:remote] = remote
    end

    def accept_call
        self[:accept_call] += 1

        if not self[:in_call]
            schedule.in('1s') do
                mute(true)
            end
        end
    end

    def hang_up
        self[:hang_up] += 1
    end

    def show_self(state)
        self[:show_self] = !!state
    end

    def mute(state)
        self[:mute] = !!state

        if @mic_mutes && !@mic_mutes.empty?
            system[:Mixer].mute(@mic_mutes, self[:mute])
        end
    end

    def video_mute(state)
        self[:video_mute] = !!state
    end

    def in_call(state)
        self[:in_call] = !!state
    end

    def room_user(name)
        self[:room_user] = name
    end

    def state(status)
        self[:state] = status
    end

    # The interface will poll the server periodically, helping discover issues
    def poll
        self[:last_polled] = Time.now.to_s
    end

    def open_dev_tools
        self[:open_dev_tools] += 1
    end

    def clear_local_storage
        self[:clear_local_storage] += 1
    end
end
