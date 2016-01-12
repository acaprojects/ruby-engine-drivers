module Microsoft; end

class Microsoft::FindMe
    include ::Orchestrator::Constants


    # Discovery Information
    uri_base 'https://findme.companyname.com'
    descriptive_name 'Microsoft FindMe Service'
    generic_name :FindMe

    # Communication settings
    keepalive true
    inactivity_timeout 10000


    def on_load
        on_update
    end
    
    def on_update
        # Configure NTLM authentication
        config {
            ntlm: {
                user: setting(:username)
                password: setting(:password)
                domain: setting(:domain)
            }
        }
    end
    
    
    # ============
    # GET REQUESTS
    # ============
    def levels
        # Example Response: [{"Building":"SYDNEY","Level":"0","Online":13},{"Building":"SYDNEY","Level":"2","Online":14},
        #                    {"Building":"SYDNEY","Level":"3","Online":18}]
        get('/FindMeService/api/MeetingRooms/BuildingLevelsWithMeetingRooms', name: :levels) do |data|
            check_resp(data) do |result|
                buildings = {}
                result.each do |level|
                    building_name = level[:Building]
                    buildings[building_name] ||= []
                    buildings[building_name] << level[:Level]
                end

                self[:buildings] = buildings
                self[:levels] = result
            end
        end
    end

    def rooms(building, level)
        # Example Response:
        # [{"Alias":"cf2020","Name":"Minogue","Building":"SYDNEY","Level":"2","LocationDescription":"2020",
        #   "X":null,"Y":null,"Capacity":4,"Features":null,"CanBeBooked":true,"PhotoUrl":null,"HasAV":false,
        #   "HasDeskPhone":true,"HasSpeakerPhone":false,"HasWhiteboard":true}]
        get("/FindMeService/api/MeetingRooms/Level/#{building}/#{level}", name: :rooms) do |data|
            check_resp(data) do |result|
                self["#{building}_#{level}"] = result

                result.each do |room|
                    self["room_#{room[:Alias]}"] = room
                end
            end
        end
    end

    def meetings(defer, building, level, start_time = Time.now, end_time = Time.end_of_day)
        start_str = Time.parse(start_time.to_s).iso8601
        end_str = Time.parse(end_time.to_s).iso8601

        # Example Response:
        # [{"ConferenceRoomAlias":"cfsydinx","Start":"2015-11-11T23:30:00+00:00","End":"2015-11-12T00:00:00+00:00",
        #   "Subject":"<meeting title>","Location":"Pty MR Syd L2 INXS (10) RT Int","BookingUserAlias":null,
        #   "StartTimeZoneName":null,"EndTimeZoneName":null}]
        get("/FindMeService/api/MeetingRooms/Level/#{building}/#{level}/#{start_str}/#{end_str}") do |data|
            check_resp(data) do |result|
                defer.resolve result
            end
        end
    end

    def user_details(*users)
        # Example Response:
        # [{"Alias":"dwatson","LastUpdate":"2015-11-12T02:25:50.017Z","Confidence":100,
        #   "Coordinates":{"Building":"SYDNEY","Level":"2","X":76,"Y":29,"LocationDescription":"2140","MapByLocationId":true},
        #   "GPS":{"Latitude":-33.796597429,"Longitude":151.1382508278,"Accuracy":0.0,"LocationDescription":null},
        #   "LocationIdentifier":null,"Status":"Located","LocatedUsing":"FixedLocation","Type":"Person","Comments":null,
        #   "ExtendedUserData":{"Alias":"dwatson","DisplayName":"David Watson","EmailAddress":"David.Watson@microsoft.com","LyncSipAddress":"dwatson@microsoft.com"}}]
        get("/FindMeService/api/ObjectLocation/Users/#{users.join(',')}", name: :users) do |data|
            check_resp(data) do |users|
                users.each do |user|
                    self["user_#{user[:Alias]}"] = user
                end
            end
        end
    end

    def users_on(defer, building, level, extended_data = false)
        # Same response as above with or without ExtendedUserData
        uri = "/FindMeService/api/ObjectLocation/Level/#{building}/#{level}"
        uri << '?getExtendedData=true' if extended_data

        get(uri) do |data|
            check_resp(data) do |users|
                defer.resolve users
            end
        end
    end

    def users_fullname(defer, *aliases)
        # Example Response: ['name1', 'name2']
        get("/FindMeService/api/ObjectLocation/Users/#{aliases.join(',')}", name: :users) do |data|
            check_resp(data) do |users|
                defer.resolve users
            end
        end
    end

    def user_image(defer, login_name)
        # Returns binary JPEG image
        get("/FindMeService/api/User/Photo/#{login_name}", name: :users) do |data|
            if data[:headers].status == 200
                defer.resolve data[:body]
                :success
            else
                :failed
            end
        end
    end


    # =============
    # POST REQUESTS
    # =============
    def schedule_meeting(user_alias, room_alias, start_time, end_time, subject = 'Room Booked')
        # Check this booking can be made
        # Make the booking

        start_str = Time.parse(start_time.to_s).iso8601
        end_str = Time.parse(end_time.to_s).iso8601

        details = self["room_#{room_alias}"]
        location = "Building #{details[:Building]} level #{details[:Level]}, #{details[:Name]} room"

        post('/FindMeService/api/MeetingRooms/ScheduleMeeting', {
            body: {
                :ConferenceRoomAlias => room_alias,
                :Start => start_str,
                :End => end_str,
                :Subject => subject,
                :Location => location,
                :BookingUserAlias => user_alias,
                :StartTimeZoneName => "AUS Eastern Standard Time",
                :EndTimeZoneName => "AUS Eastern Standard Time"
            }
        }) do |data|
            if data[:headers].status == 200
                :success
            else
                :failed
            end
        end
    end


    protected


    # JSON decode options
    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze

    def check_resp(data)
        if data[:headers].status == 200
            yield ::JSON.parse(data[:body], DECODE_OPTIONS)
            :success
        else
            :failed
        end
    end
end
