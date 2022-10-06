#!/usr/bin/env ruby

require 'time_ago_in_words'
require 'json'
require_relative 'github-graphql'

PullRequestsQuery = GitHubGraphQL::Client.parse <<-GRAPHQL
query {
  repository(name: "pr-review-club", owner: "nervosnetwork") {
    projectV2(number: 28) {
      items(first: 100) {
        nodes {
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
            }
          }
          content {
            ... on PullRequest {
              number
              url
              title
              isDraft
              additions
              deletions
              changedFiles
              createdAt
              updatedAt
              commits {
                totalCount
              }
              reviewDecision

              repository {
                name
              }
              reactions(content: EYES, last: 100) {
                nodes {
                  user {
                    login
                  }
                }
              }
              reviewRequests(last: 100) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User {
                      login
                    }
                  }
                }
              }
              latestReviews(first: 100) {
                nodes {
                  author {
                    login
                  }
                  state
                }
              }
              author {
                login
              }
            }
          }
        }
      }
    }
  }
}
GRAPHQL

def pluralize(count, singular, plural)
  if count == 1
    "#{count} #{singular}"
  else
    "#{count} #{plural}"
  end
end

def format_pr(pr)
  commits = pluralize(pr.commits.total_count, 'commit', 'commits')
  changed_files = pluralize(pr.changed_files, 'file', 'files')
  created = Time.parse(pr.created_at).ago_in_words
  updated = Time.parse(pr.updated_at).ago_in_words
  "#{pr.title} by @#{pr.author.login} (#{commits}, #{changed_files}, +#{pr.additions}-#{pr.deletions}, created #{created}, last updated #{updated}) #{pr.url}"
end

def pr_review_state(pr)
  if pr.review_decision == 'APPROVED'
    return '🟢 **Approved**'
  end

  if pr.is_draft || (pr.review_decision == 'CHANGES_REQUESTED' && pr.latest_reviews.nodes.map(&:state).include?('CHANGES_REQUESTED'))
    return '🚧 **Pending Author**'
  end

  return '🟡 **Pending Reviewers**'
end

def pr_review_state_details(pr)
  states = pr.latest_reviews.nodes.group_by(&:state)
  components = []
  if states.include?('APPROVED')
    components << "#{states['APPROVED'].size} approved"
  end
  if states.include?('CHANGES_REQUESTED')
    components << "#{states['CHANGES_REQUESTED'].size} requested changes"
  end
  if states.include?('COMMENTED')
    components << "#{states['COMMENTED'].size} commented"
  end
  if states.include?('DISMISSED')
    components << "#{states['DISMISSED'].size} dismissed"
  end
  if states.include?('PENDING')
    components << "#{states['PENDING'].size} pending"
  end

  components.join(', ')
end

def owners_bar(pr, candidates)
  assigned = pr.review_requests.nodes.map do |node|
    node.requested_reviewer&.login
  end.compact.uniq
  pr_candidates = (candidates.fetch(pr.repository.name, {}).fetch('owners', []) - assigned).shuffle
  pr_candidates.delete(pr.author.login)

  assigned_display = assigned.map{|u| "@#{u}"}.join(", ")
  candidates_display = pr_candidates.map{|u| "@#{u}"}.join(", ")

  "〔 #{assigned_display} | #{candidates_display} 〕"
end

def watchers_bar(pr, candidates)
  owners = pr.review_requests.nodes.map do |node|
    node.requested_reviewer&.login
  end.compact.uniq
  assigned = pr.reactions.nodes.map do |node|
    node.user.login
  end
  assigned -= owners

  pr_candidates = (candidates.fetch(pr.repository.name, {}).fetch('watchers', []) - assigned).shuffle
  pr_candidates.delete(pr.author.login)

  assigned_display = assigned.map{|u| "@#{u}"}.join(", ")
  candidates_display = pr_candidates.map{|u| "@#{u}"}.join(", ")

  "〔 #{assigned_display} | #{candidates_display} 〕"
end

candidates = JSON.parse(File.read("../../reviewers.json"))

prs = GitHubGraphQL::Client.query(PullRequestsQuery).data.repository.project_v2.items.nodes.filter do |node|
  node.field_value_by_name.name == "🆕 New"
end.map(&:content).shuffle

if prs.empty?
  exit 0
end

puts "> Owners/Watchers Format: 〔assignee1, assignee2 | candidate1, candidate2, ... 〕"
puts "> Candidates list are randomly shuffled"
puts ""

puts "There #{prs.size == 1 ? 'is' : 'are'} #{pluralize(prs.size, 'PR', 'PRs')} awaiting review:\n\n"

club_owners = candidates["pr-review-club"]["owners"].shuffle
slice_size = (prs.size + club_owners.size - 1) / club_owners.size
prs.each_slice(slice_size).zip(club_owners).each do |(slice_prs, owner)|
  puts "## For Club Maintainer @#{owner}\n\n"

  slice_prs.each do |pr|
    state = pr_review_state(pr)
    puts "- #{state}: #{format_pr(pr)}"
    review_state_details = pr_review_state_details(pr)
    if review_state_details != ''
      puts "    - #{review_state_details}"
    end
    puts "    - Owners: #{owners_bar(pr, candidates)}"
    puts "    - Watchers: #{watchers_bar(pr, candidates)}"
  end
end
