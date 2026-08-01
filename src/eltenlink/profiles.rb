# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper

module EltenLink
  UserProfileBirthdate = Struct.new(:year, :month, :day, keyword_init: true) do
    def complete?
      year.to_i > 1900 && month.to_i.between?(1, 12) && day.to_i.between?(1, 31)
    end
  end
  UserProfile = Struct.new(
    :name,
    :fullname,
    :gender,
    :birthdate,
    :location,
    :public_profile,
    :public_mail,
    keyword_init: true
  )

  module Profiles
    class << self
      def visiting_card(client, user)
        data = client.api_data("GET", "/api/v1/users/#{user.to_s.urlenc}/visiting-card")
        return nil unless Client.truthy?(data["exists"])

        data["text"].to_s
      end

      def set_visiting_card(client, text:)
        client.api_data("PATCH", "/api/v1/users/me/visiting-card", { "text" => text })
        true
      end

      def profile(client, user)
        payload = client.api_payload("GET", "/api/v1/users/#{user.to_s.urlenc}/profile")
        return nil unless payload.is_a?(Hash) && Client.truthy?(payload["success"])

        data = payload["data"] || {}
        birthdate = data["birthdate"] || {}
        UserProfile.new(
          name: data["name"].to_s,
          fullname: data["fullname"].to_s,
          gender: data["gender"].to_i,
          birthdate: UserProfileBirthdate.new(
            year: birthdate["year"].to_i,
            month: birthdate["month"].to_i,
            day: birthdate["day"].to_i
          ),
          location: data["location"].to_s,
          public_profile: data["public_profile"].to_i,
          public_mail: data["public_mail"].to_i
        )
      end

      def update_profile(client, fullname: nil, gender: nil, birthdate_year: nil, birthdate_month: nil, birthdate_day: nil, location: nil, public_profile: nil, public_mail: nil)
        client.api_data("PATCH", "/api/v1/users/me/profile", clean_hash(
          "fullname" => fullname,
          "gender" => gender,
          "birthdateyear" => birthdate_year,
          "birthdatemonth" => birthdate_month,
          "birthdateday" => birthdate_day,
          "location" => location,
          "publicprofile" => public_profile,
          "publicmail" => public_mail
        ))
        true
      end

      private

      def clean_hash(hash)
        hash.each_with_object({}) { |(key, value), result| result[key] = value unless value.nil? }
      end
    end
  end
end
