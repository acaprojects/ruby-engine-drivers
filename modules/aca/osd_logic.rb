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
        self.content = setting(:content)
    end

    def hdmi
        stream 'tv:brightsign.biz/hdmi'
    end

    def stream(uri)
        self.content = "stream #{uri}"
    end

    def web(url)
        self.content = "web #{url}"
    end

    def show_message(message, timeout = '10s')
        schedule.clear
        self.message = message
        schedule.in timeout { clear_message } unless is_negatory? timeout
        nil
    end

    def clear_message
        self.message = ''
    end

    # Trigger a client refresh
    def reload
        self[:reload] = true
    end

    protected

    def content=(address)
        self[:content] = address
        define_setting(:content, address)
    end

    def message=(msg)
        self[:message] = msg
    end
end
