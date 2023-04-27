# frozen_string_literal: true

require "dependabot/updater/group_update_creation"

# This class implements our strategy for refreshing a single Pull Request which
# updates all outdated Dependencies within a specific project folder that match
# a specificed Dependency Group.
#
# Refreshing a Dependency Group pull request essentially has two outcomes, we
# either update or supersede the existing PR.
#
# To decide which strategy to use, we recompute the DependencyChange on the
# current head of the target branch and:
# - determine that all the same dependencies change to the same versions
#   - in this case we update the existing PR
# - determine that one or more dependencies are now involved or removed
#   - in this case we close the existing PR and create a new one
# - determine that all the dependencies are the same, but versions have changed
#   -in this case we close the existing PR and create a new one
module Dependabot
  class Updater
    module Operations
      class RefreshGroupUpdatePullRequest
        include GroupUpdateCreation

        def self.applies_to?(job:)
          return false if job.security_updates_only?
          # If we haven't been given metadata about the dependencies present
          # in the pull request and the Dependency Group that originally created
          # it, this strategy cannot act.
          return false unless job.dependencies&.any?
          return false unless job.dependency_group_to_refresh

          job.updating_a_pull_request? && Dependabot::Experiments.enabled?(:grouped_updates_prototype)
        end

        def initialize(service:, job:, dependency_snapshot:, error_handler:)
          @service = service
          @job = job
          @dependency_snapshot = dependency_snapshot
          @error_handler = error_handler
        end

        def perform
          # This guards against any jobs being performed where the data is malformed, this should not happen unless
          # there was is defect in the service and we emitted a payload where the job and configuration data objects
          # were out of sync.
          unless dependency_snapshot.job_group
            Dependabot.logger.warn(
              "The '#{dependency_snapshot.job_group_name || "unknown"}' group has been removed from the update config."
            )

            service.capture_exception(
              error: DependabotError.new("Attempted to update a missing group."),
              job: job
            )
            return
          end

          dependency_change = compile_all_dependency_changes_for(dependency_snapshot.job_group)

          if dependency_change.updated_dependencies.any?
            Dependabot.logger.info("Updating pull request for '#{dependency_snapshot.job_group.name}'")
            begin
              service.update_pull_request(dependency_change, dependency_snapshot.base_commit_sha)
            rescue StandardError => e
              raise if ErrorHandler::RUN_HALTING_ERRORS.keys.any? { |err| e.is_a?(err) }

              # FIXME: This will result in us reporting a the group name as a dependency name
              #
              # In future we should modify this method to accept both dependency and group
              # so the downstream error handling can tag things appropriately.
              error_handler.handle_dependabot_error(error: e, dependency: group)
            end
          else
            close_pull_request(reason: :up_to_date)
          end
        end

        private

        attr_reader :job,
                    :service,
                    :dependency_snapshot,
                    :error_handler

        def close_pull_request(reason:)
          reason_string = reason.to_s.tr("_", " ")
          Dependabot.logger.info(
            "Telling backend to close pull request for the " \
            "#{dependency_snapshot.job_group.name} group " \
            "(#{job.dependencies.join(', ')}) - #{reason_string}"
          )

          service.close_pull_request(job.dependencies, reason)
        end
      end
    end
  end
end
