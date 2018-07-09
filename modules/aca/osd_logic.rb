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
        self[:content] = setting(:content) || hdmi
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

    def show_message(text, timeout = '10s')
        schedule.clear
        self.message = text
        schedule.in(timeout) { clear_message } unless is_negatory? timeout
        nil
    end

    def clear_message
        self.message = ''
    end

    # Trigger a client refresh
    def reload
        logger.debug 'Requesting client reconnect'
        self[:reload] = true
    end

    def cancel_reload
        self[:reload] = false
    end

    # Callback for client init
    def register(device_info)
        logger.debug 'Client online'
        cancel_reload
    end

    protected

    def content=(source)
        self[:content] = source
        define_setting :content, source
        source
    end

    def message=(text)
        self[:message] = text
    end
end
