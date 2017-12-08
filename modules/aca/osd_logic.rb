# frozen_string_literal: true

module Aca; end

class Aca::OsdLogic
    include ::Orchestrator::Constants

    implements :logic
    descriptive_name 'ACA On Screen Display Logic'
    generic_name :OSD

    def on_load
        on_update
    end

    def on_update
        clear_message
        stream setting(:stream_url)
    end

    def hdmi
        self.stream = 'tv:brightsign.biz/hdmi'
    end

    def stream(url)
        self.stream = url
    end

    def show_message(message, timeout = '10s')
        schedule.clear

        self.message = message

        schedule.in(timeout) { clear_message } unless is_negatory? timeout
    end

    def clear_message
        self.message = ''
    end

    protected

    def stream=(address)
        self[:stream_url] = address
        define_setting(:stream_url, address)
    end

    def message=(msg)
        self[:message] = msg
    end
end
