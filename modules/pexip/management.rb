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
        # NOTE:: base URI https://pexip.company.com
        @username = setting(:username)
        @password = setting(:password)
    end

    MeetingTypes = ["conference", "lecture", "two_stage_dialing", "test_call"]
    def new_meeting(name, type = "conference", pin: rand(9999), **options)
        type = type.to_s.strip.downcase
        raise "unknown meeting type" unless MeetingTypes.include?(type)

        post('/api/admin/configuration/v1/conference/', body: {
            name: name.to_s,
            service_type: type,
            pin: pin.to_s.rjust(4, '0')
        }.merge(options).to_json, headers: {
            'Authorization' => [@username, @password],
            'Content-Type' => 'application/json',
            'Accept' => 'application/json'
        }) do |data|
            if (200...300).include?(data.status)
                get_meeting URI(data['location']).path
            else
                :retry
            end
        end
    end

    def get_meeting(meeting)
        meeting = "/api/admin/configuration/v1/conference/#{meeting}/" unless meeting.to_s.include?("/")

        get(meeting).path, headers: {
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

    def end_meeting(meeting)
      meeting = "/api/admin/configuration/v1/conference/#{meeting}/" unless meeting.to_s.include?("/")

      delete(meeting, headers: {
          'Authorization' => [@username, @password],
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
      }) do |data|
            case data.status
            when (200...300)
              :success
            when 404
              :success
            else
              :retry
            end
        end
    end
end
