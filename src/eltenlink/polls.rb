# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper

module EltenLink
  class Poll
    attr_accessor :id, :name, :author, :description, :created, :voted, :language, :votes

    def initialize(id = 0)
      @id = id.to_i
      @name = ""
      @author = ""
      @description = ""
      @created = 0
      @voted = false
      @language = ""
      @votes = 0
    end
  end

  class PollDetails < Poll
    attr_accessor :questions

    def initialize(id = 0)
      super(id)
      @questions = []
    end
  end

  class PollResults
    attr_accessor :votes, :answers

    def initialize(votes = 0, answers = [])
      @votes = votes.to_i
      @answers = answers
    end
  end

  class PollAnswer
    attr_accessor :author, :question, :answer, :type

    def initialize(author:, question:, answer:, type: 0)
      @author = author
      @question = question.to_i
      @answer = answer
      @type = type.to_i
    end
  end

  module Polls
    class << self
      def list(client, details: 2, params: {})
        request_params = params.merge("details" => details)
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls", request_params)["polls"])
      end

      def voted?(client, poll)
        data = client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}/voted")
        data["voted"] == true || data["voted"].to_s == "1"
      end

      def delete(client, poll)
        client.api_data("DELETE", "/api/v1/polls/#{poll_id(poll)}")
        true
      end

      def create(client, name:, language:, questions:, description:, hidden: false, expirydate: nil, hideresults: false)
        params = {
          "name" => name,
          "language" => language,
          "questions" => JSON.generate(questions),
          "description" => description,
          "hidden" => hidden ? 1 : 0
        }
        params["expirydate"] = expirydate if expirydate != nil
        params["hideresults"] = hideresults ? 1 : 0 if expirydate != nil
        client.api_data("POST", "/api/v1/polls", params)
        true
      end

      def get(client, poll)
        parse_details(client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}"), poll_id(poll))
      end

      def answer(client, poll, answers)
        client.api_data("POST", "/api/v1/polls/#{poll_id(poll)}/answers", { "answers" => answers })
        true
      end

      def results(client, poll, details: 1)
        parse_results(client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}/results", { "details" => details }))
      end

      def by_me(client)
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls", { "by_me" => "1" })["polls"])
      end

      private

      def parse_poll_summaries(rows)
        rows.to_a.map do |row|
          poll = Poll.new(row["id"])
          poll.name = row["name"].to_s
          poll.author = row["author"].to_s
          poll.created = row["created"].to_i
          poll.language = row["language"].to_s
          poll.voted = row["voted"] == true || row["voted"].to_s == "1"
          poll.votes = row["votes"].to_i
          poll.description = row["description"].to_s
          poll
        end
      end

      def parse_details(data, id)
        poll = PollDetails.new(id)
        poll.name = data["name"].to_s
        poll.author = data["author"].to_s
        poll.created = Time.at(data["created"].to_i)
        poll.questions = data["questions"].is_a?(Array) ? data["questions"] : []
        poll.description = data["description"].to_s
        poll.language = data["language"].to_s
        poll
      end

      def parse_results(data)
        answers = []
        data["answers"].to_a.each do |row|
          answers.push(PollAnswer.new(
            author: row["author"].to_i,
            question: row["question"].to_i,
            answer: row["answer"].to_s
          ))
        end
        PollResults.new(data["votes"].to_i, answers)
      end

      def poll_id(poll)
        poll.respond_to?(:id) ? poll.id : poll
      end
    end
  end
end
