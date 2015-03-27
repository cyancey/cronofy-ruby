module Cronofy

  class Client

    def initialize(client_id, client_secret, token=nil, refresh_token=nil)
      @auth = Auth.new(client_id, client_secret, token, refresh_token)
    end

    def access_token!
      raise CredentialsMissingError.new unless @auth.access_token
      @auth.access_token
    end

    # Public : Lists the calendars or the user across all of the calendar accounts
    #          see http://www.cronofy.com/developers/api#calendars
    #
    # Returns Hash of calendars
    def list_calendars
      response = do_request { access_token!.get("/v1/calendars")  }
      ResponseParser.new(response).parse_json
    end

    # Public : Creates or updates an existing event that matches the event_id, in the calendar
    #          see: http://www.cronofy.com/developers/api#upsert-event
    #          aliased as upsert_event
    #
    # calendar_id   - String Cronofy ID for the the calendar to contain the event
    # event         - Hash describing the event with symbolized keys.
    #                 :event_id String client identifier for event NOT Cronofy's
    #                 :summary String
    #                 :start Time
    #                 :end Time
    #
    # Returns nothing
    def create_or_update_event(calendar_id, event)
      body = event.dup
      body[:start] = event[:start].utc.iso8601 # TODO change for whole day events
      body[:end] = event[:end].utc.iso8601

      headers = {
        'Content-Type' => 'application/json'
      }

      do_request { access_token!.post("/v1/calendars/#{calendar_id}/events", { body: JSON.generate(body), headers: headers }) }
    end
    alias_method :upsert_event, :create_or_update_event

    # Public : Returns a paged list of events within a given time period, 
    #          that you have not created, across all of a users calendars. 
    #          see http://www.cronofy.com/developers/api#read-events
    # 
    # from            - The minimum Time from which to return events. 
    # to              - The Date to return events up until.
    # tzid            - A String representing a known time zone identifier from the 
    #                   IANA Time Zone Database. 
    # include_deleted - A Boolean specifying whether events that have been deleted 
    #                   should included or excluded from the results. 
    # include_moved   - A Boolean specifying whether events that have ever existed 
    #                   within the given window should be included or excluded from 
    #                   the results. 
    # last_modified   - The Time that events must be modified on or after 
    #                   in order to be returned. 
    #
    # Returns paged Hash of events
    def read_events(from: nil, to: nil, tzid: 'Etc/UTC', include_deleted: false,
                    include_moved: false, last_modified: nil)
      params = {
        'from' => time_to_iso8601(from),
        'to' => time_to_iso8601(to),
        'tzid' => tzid,
        'include_deleted' => include_deleted.to_s,
        'include_moved' => include_moved.to_s,
        'last_modified' => time_to_iso8601(last_modified)
      }
      params.delete_if { |key, value| !value }
      
      response = do_request do
        access_token!.get('/v1/events', { params: params })
      end

      ResponseParser.new(response).parse_json
    end

    # Public : Returns a paged list of events given a page URL.
    #          Page URLs are obtained from read_events requests and 
    #          get_events_page requests (response.pages.next_page)
    #          see http://www.cronofy.com/developers/api#read-events
    # 
    # page_url - the url of a page of Read Events results
    #
    # Returns paged Hash of events
    def get_events_page(page_url)
      page_path = page_url.sub(::Cronofy.api_url, '')
      
      response = do_request { access_token!.get(page_path) }
      ResponseParser.new(response).parse_json
    end

    # Public : Deletes an event from the specified calendar
    #          see http://www.cronofy.com/developers/api#delete-event
    #
    # calendar_id   - String Cronofy ID for the calendar containing the event
    # event_id      - String client ID for the event
    #
    # Returns nothing
    def delete_event(calendar_id, event_id)
      body = { event_id: event_id }

      headers = {
        'Content-Type' => 'application/json'
      }

      do_request { access_token!.delete("/v1/calendars/#{calendar_id}/events", { body: JSON.generate(body), headers: headers }) } # TODO why in query params???
    end

    # Public : Creates a notification channel with a callback URL
    #
    # callback_url  - String URL with the callback
    #
    # Returns Hash of channel
    def create_channel(callback_url) 
      body = {
        'callback_url' => callback_url
      }
      headers = {
        'Content-Type' => 'application/json'
      }

      response = do_request do
        access_token!.post("/v1/channels",
                           {
                             body: JSON.generate(body),
                             headers: headers
                           }
                          )
      end
      
      ResponseParser.new(response).parse_json
    end

    # Public : Lists the channels of the user
    #
    # Returns Hash of channels
    def list_channels
      response = do_request {access_token!.get('v1/channels')}
      ResponseParser.new(response).parse_json
    end

    # Public : Generate the authorization URL to send the user to in order to generate
    #          and authorization code in order for an access_token to be issued
    #          see http://www.cronofy.com/developers/api#authorization
    #
    # redirect_uri  - String URI to return the user to once authorization process completed
    # scope         - Array of scopes describing access required to the users calendars (default: all scopes)
    #
    # Returns String
    def user_auth_link(redirect_uri, scope=nil)
      @auth.user_auth_link(redirect_uri, scope)
    end

    # Public : Returns the access_token for a given code and redirect_uri pair
    #          see http://www.cronofy.com/developers/api#token-issue
    #
    # code          - String code returned to redirect_uri after authorization
    # redirect_uri  - String URI returned to
    #
    # Returns Cronofy::Credentials
    def get_token_from_code(code, redirect_uri)
      @auth.get_token_from_code(code, redirect_uri)
    end

    # Public : Refreshes the access_token and periodically the refresh_token for authorization
    #          see http://www.cronofy.com/developers/api#token-refresh
    #
    # Returns Cronofy::Credentials
    def refresh_access_token
      @auth.refresh!
    end

  private

    ERROR_MAP = {
      401 => ::Cronofy::AuthenticationFailureError,
      403 => ::Cronofy::AuthorizationFailureError,
      404 => ::Cronofy::NotFoundError,
      422 => ::Cronofy::InvalidRequestError,
      429 => ::Cronofy::TooManyRequestsError
    }

    def do_request(&block)
      begin
        block.call
      rescue OAuth2::Error => e
        error_class = ERROR_MAP.fetch(e.response.status, UnknownError)
        raise error_class.new(e.response.headers['status'], e.response)
      end
    end

    def time_to_iso8601(time)
      if time
        time.utc.iso8601
      else
        nil
      end
    end

  end

  # Alias for backwards compatibility
  # depcrectated will be removed
  class Cronofy < Client

  end

end