module Pexip; end

# Documentation: https://docs.pexip.com/api_manage/api_configuration.htm#create_vmr

class Pexip::Management
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    implements :service
    descriptive_name 'Pexip Management API'
    generic_name :Meeting

    # HTTP keepalive
    keepalive false

    def on_load
        on_update
    end

    def on_update
        defaults({
            timeout: 10_000
        })

        # fallback if meetings are not ended correctly
        @vmr_ids ||= setting(:vmr_ids) || {}
        clean_up_after = setting(:clean_up_after) || 24.hours.to_i
        schedule.clear
        schedule.every("30m") { cleanup_meetings(clean_up_after) }

        # NOTE:: base URI https://pexip.company.com
        @username = setting(:username)
        @password = setting(:password)
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

    MeetingTypes = ["conference", "lecture", "two_stage_dialing", "test_call"]
    def new_meeting(name = nil, conf_alias = nil, type = "conference", pin: rand(9999), expire: true, tag: 'pstn', **options)
        type = type.to_s.strip.downcase
        raise "unknown meeting type" unless MeetingTypes.include?(type)

        conf_alias ||= SecureRandom.uuid
        name ||= conf_alias
        pin = pin.to_s.rjust(4, '0') if pin

        post('/api/admin/configuration/v1/conference/', body: {
            name: name.to_s,
            service_type: type,
            pin: pin,
            aliases: [{"alias" => conf_alias}],
            tag: tag
        }.merge(options).to_json, headers: {
            'Authorization' => [@username, @password],
            'Content-Type' => 'application/json',
            'Accept' => 'application/json'
        }) do |data|
            if (200...300).include?(data.status)
                vmr_id = URI(data['Location']).path.split("/").reject(&:empty?)[-1]
                if expire
                  @vmr_ids[vmr_id] = Time.now.to_i
                  define_setting(:vmr_ids, @vmr_ids)
                end
                vmr_id
            else
                :retry
            end
        end
    end

    def add_meeting_to_expire(vmr_id)
      @vmr_ids[vmr_id] = Time.now.to_i
      define_setting(:vmr_ids, @vmr_ids)
    end

    def get_meeting(meeting)
        meeting = "/api/admin/configuration/v1/conference/#{meeting}/" unless meeting.to_s.include?("/")

        get(meeting, headers: {
            'Authorization' => [@username, @password],
            'Content-Type' => 'application/json',
            'Accept' => 'application/json'
        }) do |data|
            case data.status
            when (200...300)
              JSON.parse(data.body, symbolize_names: true)
            when 404
              :abort
            else
              :retry
            end
        end
    end

    def end_meeting(meeting, update_ids = true)
      meeting = "/api/admin/configuration/v1/conference/#{meeting}/" unless meeting.to_s.include?("/")

      delete(meeting, headers: {
          'Authorization' => [@username, @password],
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
      }) do |data|
            case data.status
            when (200...300)
              define_setting(:vmr_ids, @vmr_ids) if update_ids && @vmr_ids.delete(meeting.to_s)
              :success
            when 404
              define_setting(:vmr_ids, @vmr_ids) if update_ids && @vmr_ids.delete(meeting.to_s)
              :success
            else
              :retry
            end
        end
    end

    def cleanup_meetings(older_than)
      time = Time.now.to_i
      delete = []
      @vmr_ids.each do |id, created|
        delete << id if (created + older_than) <= time
      end
      promises = delete.map { |id| end_meeting(id, false) }
      thread.all(*promises).then do
        delete.each { |id| @vmr_ids.delete(id) }
        define_setting(:vmr_ids, @vmr_ids)
      end
      nil
    end

    def dial_phone(meeting_alias, phone_number)
      phone_number = phone_number.gsub(/\s/, "")

      body = if phone_number.start_with?("+")
        {
          call_type: 'audio',
          role: 'guest',
          routing: 'routing_rule',
          conference_alias: meeting_alias,
          destination: "#{phone_number}@conference.meet.health.nsw.gov.au",
          protocol: 'sip',
          system_location: 'UN_InternalWebRTC_SIPH323_Proxy'
        }
      else
        {
          call_type: 'audio',
          role: 'guest',
          routing: 'routing_rule',
          conference_alias: meeting_alias,
          destination: phone_number,
          protocol: 'h323',
          system_location: 'UN_InternalWebRTC_SIPH323_Proxy'
        }
      end

      post('/api/admin/command/v1/participant/dial/',
        body: body.to_json,
        headers: {
          'Authorization' => [@username, @password],
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
        }
      ) do |data|
          if (200...300).include?(data.status)
              response = JSON.parse(data.body, symbolize_names: true)
              if response[:status] == "success"
                # {participant_id: "5acac442-7a25-44fa-badf-4bc725a0f035", participant_ids: ["5acac442-7a25-44fa-badf-4bc725a0f035"]}
                response[:data]
              else
                :abort
              end
          else
              :abort
          end
      end
    end
end
