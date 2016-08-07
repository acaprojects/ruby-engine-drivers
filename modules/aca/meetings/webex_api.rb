module Aca; end
module Aca::Meetings; end


require "uri"
require "net/http"
require "rest-client"
require "nokogiri"



class Aca::Meetings::WebexApi
    TimezoneMap = { "Eniwetok" => 0, "Samoa" => 1, "Honolulu" => 2, "Anchorage" => 3, "San Jose" => 4,
        "Arizona" => 5, "Denver" => 6, "Chicago" => 7, "Mexico City, Tegucigalpa" => 8, "Regina" => 9,
        "Bogota" => 10, "New York" => 11, "Indiana" => 12, "Halifax" => 13, "Caracas" => 14, "Newfoundland" => 15,
        "Brasilia" => 16, "Buenos Aires" => 17, "Mid-Atlantic" => 18, "Azores" => 19, "Casablanca" => 20,
        "London" => 21, "Amsterdam" => 22, "Paris" => 23, "Deprecated" => 24, "Berlin" => 25, "Athens" => 26,
        "Deprecated" => 27, "Cairo" => 28, "Pretoria" => 29, "Helsinki" => 30, "Tel Aviv" => 31, "Baghdad" => 32,
        "Moscow" => 33, "Nairobi" => 34, "Tehran" => 35, "Abu Dhabi, Muscat" => 36, "Baku" => 37, "Kabul" => 38,
        "Ekaterinburg" => 39, "Islamabad" => 40, "Bombay" => 41, "Columbo" => 42, "Almaty" => 43, "Bangkok" => 44,
        "Beijing" => 45, "Perth" => 46, "Singapore" => 47, "Hong Kong" => 48, "Tokyo" => 49, "Seoul" => 50,
        "Yakutsk" => 51, "Adelaide" => 52, "Darwin" => 53, "Brisbane" => 54, "Sydney" => 55, "Guam" => 56,
        "Hobart" => 57, "Vladivostok" => 58, "Solomon Is" => 59, "Wellington" => 60, "Fiji" => 61 }


    def initialize(username, password)
        @username = username
        @password = password
    end

    def create_booking(subject:, description:, pin:, attendee:, start:, duration:, timezone:, host: nil, host_pin: nil, **options)
        if start.class == String
            start = Time.parse(start)
        elsif start.class == Integer || start.class == Fixnum
            start = Time.at(start)
            start.in_time_zone(timezone)
        end

        builder = Nokogiri::XML::Builder.new do |xml|
                xml.message('xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance') {
                    xml.header {
                        xml.securityContext {
                            xml.webExID @username
                            xml.password @password
                            xml.siteID '1017412' # Might be worth changing this to an env variable in the future
                        }
                    }
                    xml.body {
                        xml.bodyContent('xsi:type' => 'java:com.webex.service.binding.meeting.CreateMeeting') {
                            xml.accessControl {
                                xml.meetingPassword pin
                            }
                            xml.metaData {
                                xml.confName subject
                                xml.meetingType 3
                                xml.agenda description
                            }
                            xml.participants {
                                xml.maxUserNumber 99
                                xml.attendees {
                                    xml.attendee {
                                        xml.person {
                                            xml.name attendee[:name]
                                            xml.email attendee[:email]
                                        }
                                    }
                                }
                            }
                            xml.enableOptions {
                                xml.chat true
                                xml.poll true
                                xml.audioVideo true
                            }
                            xml.schedule {
                                xml.hostWebExID host if host
                                xml.hostKey host_pin if host_pin
                                xml.startDate start.strftime('%m/%d/%Y %H:%M:%S')
                                xml.openTime 900
                                xml.joinTeleconfBeforeHost true
                                xml.duration duration
                                xml.timeZoneID TimezoneMap[timezone.to_s]
                            }
                            xml.telephony {
                                xml.telephonySupport 'CALLIN'
                            }
                        }
                    }
                }
        end

        xml_string = builder.to_xml
        url = "https://jlta.webex.com/WBXService/XMLService"
        response = RestClient.post url, xml_string, :content_type => "text/xml"

        xml_response = Nokogiri::XML(response.body)
        xml_response.to_xml

        check_result = xml_response.remove_namespaces!.css('result').text
        if check_result == 'FAILURE'
            raise "failed to create booking #{xml_response.css('reason').text}"
        end

        booking_response = {
            id: xml_response.css('meetingkey').text
        }

        return booking_response
    end

    def get_booking(id)
        builder = Nokogiri::XML::Builder.new do |xml|
                xml.message('xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance') {
                    xml.header {
                        xml.securityContext {
                            xml.webExID @username
                            xml.password @password
                            xml.siteID '1017412' # Might be worth changing this to an env variable in the future
                        }
                    }
                    xml.body {
                        xml.bodyContent('xsi:type' => 'java:com.webex.service.binding.meeting.GetMeeting') {
                            xml.meetingKey id
                        }
                    }
                }
        end

        xml_string = builder.to_xml
        url = "https://jlta.webex.com/WBXService/XMLService"
        response = RestClient.post url, xml_string, :content_type => "text/xml"
        xml_response = Nokogiri::XML(response.body)

        booking_response = {
            id: id,
            subject: xml_response.remove_namespaces!.css('confName').text,
            description: xml_response.remove_namespaces!.css('agenda').text,
            start: xml_response.remove_namespaces!.css('startDate').text,
            timezone:  xml_response.remove_namespaces!.css('timeZone').text,
            duration:  xml_response.remove_namespaces!.css('duration').text,
            host_id:  xml_response.remove_namespaces!.css('hostWebExID').text,
            password: xml_response.remove_namespaces!.css('meetingPassword').text
        }

        return booking_response
    end

    def update_booking(id:, start: nil, timezone: nil, duration: nil, host: nil)
        if start.class == String
            start = Time.parse(start)
        elsif start.class == Integer || start.class == Fixnum
            start = Time.at(start)
            start.in_time_zone(timezone) if timezone
        end

        builder = Nokogiri::XML::Builder.new do |xml|
            xml.message('xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance') {
                xml.header {
                    xml.securityContext {
                        xml.webExID @username
                        xml.password @password
                        xml.siteID '1017412' # Might be worth changing this to an env variable in the future
                    }
                }
                xml.body {
                    xml.bodyContent('xsi:type' => 'java:com.webex.service.binding.meeting.SetMeeting') {
                        xml.schedule {
                            xml.hostWebExID host if host
                            xml.startDate(start.strftime('%m/%d/%Y %H:%M:%S')) if start
                            xml.duration duration if duration
                        }
                        xml.meetingkey id
                    }
                }
            }
        end

        xml_string = builder.to_xml
        url = "https://jlta.webex.com/WBXService/XMLService"
        response = RestClient.post url, xml_string, :content_type => "text/xml"
        xml_response = Nokogiri::XML(response.body)
        return xml_response.remove_namespaces!.css('result').text
    end

    def delete_booking(id, host = nil)
        builder = Nokogiri::XML::Builder.new do |xml|
                xml.message('xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance') {
                    xml.header {
                        xml.securityContext {
                            xml.webExID @username
                            xml.password @password
                            xml.siteID '1017412' # Might be worth changing this to an env variable in the future
                        }
                    }
                    xml.body {
                        xml.bodyContent('xsi:type' => 'java:com.webex.service.binding.meeting.DelMeeting') {
                            xml.meetingKey id
                        }
                    }
                }
        end

        xml_string = builder.to_xml
        url = "https://jlta.webex.com/WBXService/XMLService"
        response = RestClient.post url, xml_string, :content_type => "text/xml"
        xml_response = Nokogiri::XML(response.body)
        return xml_response.remove_namespaces!.css('result').text
    end
end
