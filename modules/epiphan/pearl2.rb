module Epiphan; end

class Epiphan::Pearl2
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    implements :service
    descriptive_name 'Epiphan Pearl 2'
    generic_name :Recorder

    # Communication settings
    keepalive false

    def on_load
        on_update
    end

    def on_update
        @username = setting(:username) || 'admin'
        @password = setting(:password) || ''

        defaults({
            headers: {
                authorization: [@username, @password]
            }
        })
    end

    def connected
        schedule.every('30s', true) { status }
    end

    def status(channel = 1)
        exec('recorder_status', channel) do |data|
            detail = JSON.parse(data.body, symbolize_names: true)
            self[:recording] = !detail[:state].empty?
            self[:time] = detail[:time]
            self[:total] = detail[:total]
            self[:state] = detail[:state]
            self[:active] = detail[:active]
        end
    end

    def record(channel = 1)
        exec('start_recorder', channel) do |data|
            self[:recording] = true
            self["channel#{channel}"] = :recording
            status
        end
    end

    def stop(channel = 1)
        exec('stop_recorder', channel) do |data|
            self["channel#{channel}"] = :idle
            status
        end
    end

    protected

    def time_stamp
        time = (Time.now.to_f * 1000).to_i
    end

    def exec(cmd, channel)
        get("/admin/ajax/#{cmd}.cgi?channel=#{channel}&_=#{time_stamp}") do |data|
            if data.status == 200
                yield data
                :success
            else
                :abort
            end
        end
    end
end
