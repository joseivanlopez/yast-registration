# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2013 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------
#
# Summary: Ask user for the SCC credentials
#

# use external rubygem for SCC communication
require "yast/suse_connect"

require "cgi"

require "registration/addon"
require "registration/exceptions"
require "registration/helpers"
require "registration/connect_helpers"
require "registration/sw_mgmt"
require "registration/storage"
require "registration/url_helpers"
require "registration/registration"
require "registration/registration_ui"
require "registration/ui/addon_eula_dialog"
require "registration/ui/addon_selection_dialog"
require "registration/ui/addon_reg_codes_dialog"
require "registration/ui/registered_system_dialog"
require "registration/ui/base_system_registration_dialog"
require "registration/ui/media_addon_workflow"

module Yast
  class InstSccClient < Client
    include Yast::Logger
    extend Yast::I18n

    # popup message
    CONTACTING_MESSAGE = N_("Contacting the Registration Server")

    def main
      textdomain "registration"
      import_modules

      first_run

      @selected_addons = ::Registration::Storage::InstallationOptions.instance.selected_addons

      initialize_regcodes

      # started from the add-on module?
      if WFM.Args[0] == "register_media_addon"
        if WFM.Args[1].is_a?(Fixnum)
          ::Registration::UI::MediaAddonWorkflow.run(WFM.Args[1])
        else
          log.warn "Invalid argument: #{WFM.Args[1].inspect}, a Fixnum is expected"
          log.warn "Starting the standard workflow"
          start_workflow
        end
      else
        start_workflow
      end
    end

    private

    def import_modules
      Yast.import "UI"
      Yast.import "Popup"
      Yast.import "GetInstArgs"
      Yast.import "Wizard"
      Yast.import "Report"
      Yast.import "Mode"
      Yast.import "Stage"
      Yast.import "Label"
      Yast.import "Sequencer"
      Yast.import "Installation"
    end

    # initialize known reg. codes
    def initialize_regcodes
      @known_reg_codes = ::Registration::Storage::RegCodes.instance.reg_codes
      if @known_reg_codes
        log.info "Known reg codes: #{@known_reg_codes.size} codes"
        return
      end

      @known_reg_codes = {}

      # cache the values
      ::Registration::Storage::RegCodes.instance.reg_codes = @known_reg_codes
    end

    def register_base_system
      base_reg_dialog = ::Registration::UI::BaseSystemRegistrationDialog.new
      ret = base_reg_dialog.run

      # remember the created registration object for later use
      @registration = base_reg_dialog.registration if ret == :next

      ret
    end

    # update system registration, update the target distribution
    # @return [Boolean] true on success
    def update_system_registration
      return false if init_registration == :cancel
      registration_ui.update_system
    end

    # update base product registration
    # @return [Boolean] true on success
    def refresh_base_product
      return false if init_registration == :cancel

      success, product_service = registration_ui.update_base_product

      if success && product_service && !registration_ui.install_updates?
        return registration_ui.disable_update_repos(product_service)
      end

      success
    end

    def refresh_addons
      addons = get_available_addons
      if addons == :cancel
        # With the current code, this should never happen because
        # #get_available_addons will not return :cancel if
        # #refresh_base_product returned a positive value, but
        # it's better to stay safe and abort nicely.
        return false
      end

      failed_addons = registration_ui.update_addons(addons,
        enable_updates: registration_ui.install_updates?)

      # if update fails preselest the addon for full registration
      failed_addons.each(&:selected)

      true
    end

    # display the registration update dialog
    def show_registration_update_dialog
      Wizard.SetContents(
        _("Registration"),
        Label(_("Registration is being updated...")),
        _("The previous registration is being updated."),
        GetInstArgs.enable_back,
        GetInstArgs.enable_next || Mode.normal
      )
    end

    def update_registration
      show_registration_update_dialog

      if update_system_registration && refresh_base_product && refresh_addons
        log.info "Registration update succeeded"
        :next
      else
        # force reinitialization to allow to use a different URL
        @registration = nil
        # automatic registration refresh during system upgrade failed, register from scratch
        Report.Error(_("Automatic registration upgrade failed.\n" \
              "You can manually register the system from scratch."))
        return :register
      end
    end

    # run the addon selection dialog
    def select_addons
      # FIXME: available_addons is called just to fill cache with popup
      return :cancel if get_available_addons == :cancel

      # FIXME: workaround to reference between old way and new storage in Addon metaclass
      @selected_addons = Registration::Addon.selected
      ::Registration::Storage::InstallationOptions.instance.selected_addons = @selected_addons

      Registration::UI::AddonSelectionDialog.run(@registration)
    end

    # load available addons from SCC server
    # the result is cached to avoid reloading when going back and forth in the
    # installation workflow
    def get_available_addons
      # cache the available addons
      return :cancel if init_registration == :cancel

      registration_ui.get_available_addons
    end

    # register all selected addons
    def register_addons
      return false if init_registration == :cancel
      registration_ui.register_addons(@selected_addons, @known_reg_codes)
    end

    def report_no_base_product
      # error message
      msg = _("The base product was not found,\ncheck your system.") + "\n\n"

      if Stage.initial
        # TRANSLATORS: %s = bugzilla URL
        msg += _("The installation medium or the installer itself is seriously broken.\n" \
            "Report a bug at %s.") % "https://bugzilla.suse.com"
      else
        msg += _("Make sure a product is installed and /etc/products.d/baseproduct\n" \
            "is a symlink pointing to the base product .prod file.")
      end

      Report.Error(msg)
    end

    def registration_check
      # check the base product at start to avoid problems later
      if ::Registration::SwMgmt.find_base_product.nil?
        report_no_base_product
        return Mode.normal ? :abort : :auto
      end

      if Mode.update
        Wizard.SetContents(
          _("Registration"),
          Empty(),
          # no help text needed, the dialog displays just a progress message
          "",
          false,
          false
        )

        ::Registration::SwMgmt.copy_old_credentials(Installation.destdir)

        if File.exist?(::Registration::Registration::SCC_CREDENTIALS)
          # update the registration using the old credentials
          return :update
        end
      end

      if Mode.normal && ::Registration::Registration.is_registered?
        log.info "The system is already registered, displaying registered dialog"
        return ::Registration::UI::RegisteredSystemDialog.run
      else
        return :register
      end
    end

    def addon_eula
      ::Registration::UI::AddonEulaDialog.run(@selected_addons)
    end

    def update_autoyast_config
      options = ::Registration::Storage::InstallationOptions.instance
      return :next unless Mode.installation && options.base_registered

      log.info "Updating Autoyast config"
      config = ::Registration::Storage::Config.instance
      config.import(::Registration::Helpers.collect_autoyast_config(@known_reg_codes))
      config.modified = true
      :next
    end

    def pkg_manager
      # during installation the products are installed together with the base
      # product, run the package manager only in installed system
      return :next unless Mode.normal

      ::Registration::SwMgmt.select_addon_products

      WFM.call("sw_single")
    end

    def registration_ui
      ::Registration::RegistrationUI.new(@registration)
    end

    def workflow_aliases
      {
        # skip this when going back
        "check"                  => [->() { registration_check }, true],
        "register"               => ->() { register_base_system },
        "select_addons"          => ->() { select_addons },
        "update"                 => [->() { update_registration }, true],
        "addon_eula"             => ->() { addon_eula },
        "register_addons"        => ->() { register_addons },
        "update_autoyast_config" => ->() { update_autoyast_config },
        "pkg_manager"            => ->() { pkg_manager }
      }
    end

    # UI workflow definition
    def start_workflow
      sequence = {
        "ws_start"               => workflow_start,
        "check"                  => {
          auto:       :auto,
          abort:      :abort,
          cancel:     :abort,
          register:   "register",
          extensions: "select_addons",
          update:     "update",
          next:       :next
        },
        "update"                 => {
          abort:    :abort,
          cancel:   :abort,
          next:     "select_addons",
          register: "register"
        },
        "register"               => {
          abort:  :abort,
          cancel: :abort,
          skip:   :next,
          next:   "select_addons"
        },
        "select_addons"          => {
          abort:  :abort,
          skip:   "update_autoyast_config",
          cancel: "check",
          next:   "addon_eula"
        },
        "addon_eula"             => {
          abort: :abort,
          next:  "register_addons"
        },
        "register_addons"        => {
          abort: :abort,
          next:  "update_autoyast_config"
        },
        "update_autoyast_config" => {
          abort: :abort,
          next:  "pkg_manager"
        },
        "pkg_manager"            => {
          abort: :abort,
          next:  :next
        }
      }

      log.info "Starting scc sequence"
      Sequencer.Run(workflow_aliases, sequence)
    end

    # which dialog should be displayed at start
    def workflow_start
      log.debug "WFM.Args: #{WFM.Args}"

      if WFM.Args.include?("select_extensions") && Registration::Registration.is_registered?
        "select_addons"
      else
        "check"
      end
    end

    # initialize the Registration object
    # @return [Symbol, nil] returns :cancel if the URL selection was canceled
    def init_registration
      return if @registration

      url = ::Registration::UrlHelpers.registration_url
      return :cancel if url == :cancel
      log.info "Initializing registration with URL: #{url.inspect}"
      @registration = ::Registration::Registration.new(url)
    end

    def first_run
      return unless ::Registration::Storage::Cache.instance.first_run

      ::Registration::Storage::Cache.instance.first_run = false

      return unless Stage.initial && ::Registration::Registration.is_registered?

      ::Registration::Helpers.reset_registration_status
    end
  end unless defined?(InstSccClient)
end

Yast::InstSccClient.new.main
