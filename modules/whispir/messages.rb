module Whispir; end

# Documentation: https://whispir.github.io/api/#messages

class Whispir::Messages
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    implements :service
    descriptive_name 'Whispir messages service'
    generic_name :SMS

    # HTTP keepalive
    keepalive false

    def on_load
        on_update
    end

    def on_update
        # NOTE:: base URI https://api.messagemedia.com
        @username = setting(:username)
        @password = setting(:password)
        @api_key = setting(:api_key)
        proxy = setting(:proxy)
        if proxy
            config({
                proxy: {
                    host: proxy[:host],
                    port: proxy[:port]
                }
            })
        end
    end

    def sms(text, numbers, source = nil)
        text = text.to_s
        numbers = Array(numbers)

        post("/messages?apikey=#{@api_key}", body: {
            to: numbers.join(";"),
            # As far as I can tell, this field is not passed to the recipients
            subject: "PlaceOS Notification",
            body:    text,
        }.to_json, headers: {
            'Authorization' => [@username, @password],
            "Content-Type"  => "application/vnd.whispir.message-v1+json",
            "Accept"        => "application/vnd.whispir.message-v1+json",
            "x-api-key"     => @api_key,
        })
    end

    def received(data, resolve, command)
        if data.status == 202
            :success
        else
            :retry
        end
    end
end
