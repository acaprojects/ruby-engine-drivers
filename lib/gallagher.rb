require 'savon'
require 'active_support/time'

# gallagher = Gallagher.new(
#     username: 'system',
#     password: 'system',
#     endpoint: 'https://DESKTOP-ABH46ML:8082/Cardholder/',
#     namespace: 'http://www.gallagher.co/security/commandcentre/webservice',
#     namespaces: {"xmlns:wsdl" => "http://www.gallagher.co/security/commandcentre/cifws", "xmlns:web" => 'http://www.gallagher.co/security/commandcentre/webservice'},
#     wsdl: 'https://DESKTOP-ABH46ML:8082/Cardholder/?WSDL',
#     cert_path: './client_cert.pem',
#     ca_cert_path: './ca_cert.pem',
#     key_path: './key.pem',
#     log: false,
#     log_level: nil
#     )


# gallagher.has_cardholder("435")

# gallagher.get_cards("435")
# gallagher.set_access('435', 'T2 Shared', Time.now.utc.iso8601, (Time.now + 3.hours).utc.iso8601)

class Gallagher
    def initialize(
            username:,
            password:,
            endpoint:,
            namespace:,
            namespaces:,
            wsdl:,
            cert_path:,
            ca_cert_path:,
            key_path:,
            log: false,
            log_level: :debug
        )
        
        savonConfig = {
            :endpoint => endpoint,
            :namespace => namespace,
            :wsdl => wsdl,
            :log => log,
            :log_level => log_level,
            :ssl_version => :TLSv1_2,
            :ssl_cert_file => cert_path,
            :ssl_ca_cert_file => ca_cert_path,
            :ssl_cert_key_file => key_path,
            :open_timeout => 600,
            :read_timeout => 600,
            :env_namespace => :soapenv
        }

        @auth_client = Savon.client savonConfig

        savonConfig_req = {
            :endpoint => endpoint,
            :namespaces => namespaces,
            :wsdl => wsdl,
            :log => log,
            :log_level => log_level,
            :ssl_version => :TLSv1_2,
            :ssl_cert_file => cert_path,
            :ssl_ca_cert_file => ca_cert_path,
            :ssl_cert_key_file => key_path,
            :open_timeout => 600,
            :read_timeout => 600
        }

        @client = Savon.client savonConfig_req
        @username = username
        @password = password
    end


    def gallagher_token
        @gallagher_token ||= @auth_client.call(:connect, message: {
            'wsdl:clientVersion': '4',
            'wsdl:username': @username,
            'wsdl:password': @password
        }).body[:connect_response][:connect_result][:value]
    end


    def has_cardholder(vivant_id)
        begin
            response = @client.call(:cif_get_cardholder_pdf, message: {
                'wsdl:sessionToken': { 'web:Value': gallagher_token},
                'wsdl:id': {
                    'wsdl:PdfName': 'Unique ID',
                    'wsdl:Value': vivant_id
                },
                'wsdl:pdfName': 'Unique ID'
            })
            # Will error before this if no cardholder
            return true
        rescue Savon::SOAPFault => e
            if e.message =~ /could not be found/
                return false
            end
        end
    end

    def create_cardholder(user)
        begin
            response = @client.call(:cif_create_cardholder_ex, message: {
                'wsdl:sessionToken': { 'web:Value': gallagher_token},
                'wsdl:id': {
                    'wsdl:PdfName': 'Unique ID',
                    'wsdl:Value': "cardholder--#{user[:id]}"
                },
                'wsdl:division': 'Tower 2 Division',
                'wsdl:accessGroup': 'T2 Shared',
                'wsdl:firstName': "#{user[:first_name]}",
                'wsdl:lastName': "#{user[:last_name]}",
                'wsdl:shortName': "#{user[:first_name]}",
                'wsdl:isAuthorised': true,
                'wsdl:isExtendedAccessTimeUsed': true
            })
            return response.body[:connect_response][:connect_result][:value]
        rescue Savon::SOAPFault => e
            return e.massage
        end
    end

    def create_card(vivant_id)
        begin
            response = @client.call(:cif_issue_card_ex, message: {
                'wsdl:sessionToken': { 'web:Value': gallagher_token},
                'wsdl:id': {
                    'wsdl:PdfName': 'Unique ID',
                    'wsdl:Value': vivant_id
                },
                'wsdl:cardType': 'C4 Base Building',
                'wsdl:cardNumber': {
                    'wsdl:UseDefault': true
                },
                'wsdl:activationTime': {
                    'wsdl:UseDefault':true
                },
                'wsdl:expiryTime': {
                    'wsdl:UseDefault':true
                },
                'wsdl:isEnabled': {
                    'wsdl:UseDefault':true
                },
                'wsdl:issueLevel': {
                    'wsdl:UseDefault':true
                }
            })
            return response.body[:connect_response][:connect_result][:value]
        rescue Savon::SOAPFault => e
            return e.message
        end
    end

    def get_cards(vivant_id)
        response = @client.call(:cif_query_cards_by_cardholder, message: {
            'wsdl:sessionToken': { 'web:Value': gallagher_token},
            'wsdl:id': {
                'wsdl:PdfName': 'Unique ID',
                'wsdl:Value': vivant_id
            }
        })
        card_list = response.body[:cif_query_cards_by_cardholder_response][:cif_query_cards_by_cardholder_result]
        if card_list.key?(:cif_card)
            return card_list[:cif_card]
        else
            return []
        end
    end

    def has_cards(vivant_id)
        return get_cards(vivant_id).empty?
    end

    def set_access(vivant_id, access_group, time_start, time_end)
        # Add five minutes to time start 
        time_start = (Time.parse(time_start) - 10.minutes).utc.iso8601
        time_end = (Time.parse(time_end) + 10.minutes).utc.iso8601
        begin
            response = @client.call(:cif_assign_temporary_access, message: {
                'wsdl:sessionToken': { 'web:Value': gallagher_token},
                'wsdl:id': {
                    'wsdl:PdfName': 'Unique ID',
                    'wsdl:Value': vivant_id
                },
                'wsdl:accessGroup': access_group,
                'wsdl:activationTime': {
                    'wsdl:OtherwiseValue': time_start,
                    'wsdl:UseDefault': false
                },
                'wsdl:expiryTime': {
                    'wsdl:OtherwiseValue': time_end,
                    'wsdl:UseDefault':false
                }
            })
            return response.http.code
        rescue Savon::SOAPFault => e
            return e.message
        end
    end


    def set_pdf(vivant_id, pdf_name, pdf_value)
        # Add five minutes to time start 
        method_name = 'cif_update_cardholder_pdf'
        begin
            response = @client.call(method_name.to_sym,
                message: {
                'wsdl:sessionToken': { 'web:Value': gallagher_token},
                'wsdl:id': {
                    'wsdl:PdfName': 'Unique ID',
                    'wsdl:Value': "cardholder--#{vivant_id}"
                },
                'wsdl:pdfValue': {
                    :'@i:type' => 'web:PdfGeneralValue',
                    :'@xmlns:i' => 'http://www.w3.org/2001/XMLSchema-instance',
                    'web:Name': pdf_name,
                    'web:Type': 'StrEnum',
                    'web:Value': pdf_value
                }
            })
            return response.body[(method_name + '_response').to_sym]
        rescue Savon::SOAPFault => e
            return e.message
        end
    end
end



