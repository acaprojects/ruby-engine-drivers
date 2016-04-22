require 'protocols/oauth'
require 'nokogiri' # xml parsing


module Haivision; end
class Haivision::FurnaceServer
    include ::Orchestrator::Constants


    # Discovery Information
    uri_base 'http://server.address'
    descriptive_name 'Haivision IPTV Furnace Server'
    generic_name :IPTV

    # Communication settings
    keepalive false
    inactivity_timeout 1500


    def on_load
        on_update
    end
    

    # =====================================
    # Hook into HTTP request via middleware
    # =====================================
    def on_update
        @oauth = Protocols::OAuth.new({
            key:    setting(:consumer_key),
            secret: setting(:consumer_secret),
            site:   remote_address
        })
        update_middleware
    end

    def connected
        update_middleware
    end
    # =====================================
    

    def power(state, box_id)
        result = is_affirmative?(state)
        req = result ? 'on' : 'off'
        send_cmd :power, "<action type=\"power\"><value>#{req}</value></action>", box_id do
            self[:"#{box_id}_power"] = result
        end
    end

    def channel(number, box_id)
        send_cmd :channel, "<action type=\"channel\"><value>#{number}</value></action>", box_id do
            self[:"#{box_id}_channel"] = number
        end
    end

    def volume(val, box_id)
        vol = in_range(val.to_i, 100)
        send_cmd :volume, "<action type=\"volume\"><value>#{vol}</value></action>", box_id do
            self[:"#{box_id}_volume"] = vol
        end
    end

    def mute(state, box_id)
        result = is_affirmative?(state)
        req = result ? 'on' : 'off'
        send_cmd :mute, "<action type=\"power\"><value>#{req}</value></action>", box_id do
            self[:"#{box_id}_mute"] = result
        end
    end

    def url(uri, box_id)
        send_cmd :url, "<action type=\"url\"><value>#{uri}</value></action>", box_id
    end


    protected


    def process_response(data)
        xml = Nokogiri::XML(data)
        error = xml.xpath("//response//error//code").children.to_s

        if error.empty?
            logger.debug { "recieved #{data}" }
            :success
        else
            message = xml.xpath("//response//error//message").children.to_s
            logger.warn "error #{error}: #{message}"
            :abort
        end
    end

    RestrictStart = '<restrict_to><conditions operator="OR"><condition type="macaddr"><value>'
    RestrictEnd = '</value></condition></conditions></restrict_to>'
    def send_cmd(name, data, box_id)
        message = "<command><actions>#{data}</actions>#{RestrictStart}#{box_id}#{RestrictEnd}</command>"
        logger.debug { "Requesting #{message}" }
        post('/apis/commands', body: message, name: "#{box_id}_#{name}") do |resp|
            result = process_response(resp.body)
            yield if result == :success && block_given?
            result
        end
    end

    def update_middleware
        mid = middleware
        mid.clear
        mid << @oauth
    end
end
