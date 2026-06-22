import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { withPluginApi } from "discourse/lib/plugin-api";
import DiscourseURL from "discourse/lib/url";
import getUrl from "discourse-common/lib/get-url";
import CustomWizardTextareaEditor from "../components/custom-wizard-textarea-editor";

export default {
  name: "custom-wizard-edits",
  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.custom_wizard_enabled) {
      return;
    }

    const existing = DiscourseURL.routeTo;
    DiscourseURL.routeTo = function (path, opts) {
      if (path && path.indexOf("/w/") > -1) {
        return (window.location = path);
      }
      return existing.apply(this, [path, opts]);
    };

    withPluginApi("0.8.36", (api) => {
      api.modifyClass(
        "component:d-navigation",
        (Superclass) =>
          class extends Superclass {
            @action
            clickCreateTopicButton() {
              let createTopicWizard = this.get(
                "category.custom_fields.create_topic_wizard"
              );
              if (createTopicWizard) {
                window.location.href = getUrl(`/w/${createTopicWizard}`);
              } else {
                super.clickCreateTopicButton();
              }
            }
          }
      );

      api.modifyClass("component:d-editor", {
        pluginId: "custom-wizard",

        setupEditorMode() {
          if (this.wizardComposer) {
            // Default the wizard composer to the rich text editor when the
            // site supports it. Without explicitly initialising
            // `isRichEditorEnabled` the d-editor toggle starts in an
            // "undefined" state, which is why the user previously had to
            // click the MD/Editor switch twice to actually land on the rich
            // text view.
            if (
                this.isRichEditorEnabled === undefined ||
                this.isRichEditorEnabled === null
            ) {
              this.isRichEditorEnabled = !!(
                  this.siteSettings && this.siteSettings.rich_editor
              );
            }

            const result = this._super(...arguments);

            // If we end up in the textarea (Markdown) mode, swap in our
            // wizard-aware textarea editor so the smart-list bindings keep
            // working as before.
            if (!this.isRichEditorEnabled) {
              this.editorComponent = CustomWizardTextareaEditor;
            }

            return result;
          }
          return this._super(...arguments);
        },

        didInsertElement() {
          this._super(...arguments);

          if (this.wizardComposer) {
            this.appEvents.on(
              `wizard-editor:insert-text`,
              this,
              "_wizardInsertText"
            );
            this.appEvents.on(
              "wizard-editor:replace-text",
              this,
              "_wizardReplaceText"
            );
          }
        },

        _wizardInsertText(text, options) {
          if (
            this.session.wizardEventFieldId === this.fieldId &&
            this.element
          ) {
            this.textManipulation.insertText(text, options);
          }
        },

        _wizardReplaceText(oldVal, newVal, opts = {}) {
          if (this.session.wizardEventFieldId === this.fieldId) {
            this.textManipulation.replaceText(oldVal, newVal, opts);
          }
        },
      });

      api.modifyClass("component:category-chooser", {
        pluginId: "custom-wizard",

        categoriesByScope(options = {}) {
          let categories = this._super(options);
          const currentUser = this.currentUser;
          if (!currentUser?.staff) {
            categories = categories.filter((category) => {
              return !category.custom_fields?.create_topic_wizard;
            });
          }
          return categories;
        },
      });

      api.addAdminSidebarSectionLink("plugins", {
        name: "admin_wizards",
        label: "admin.wizard.nav_label",
        route: "adminWizardsWizard",
        icon: "hat-wizard",
      });

      if (api.getCurrentUser()?.admin) {
        api.modifyClass("model:admin-user", {
          pluginId: "custom-wizard",

          clearWizardRedirect(user) {
            return ajax(`/admin/users/${user.id}/wizards/clear_redirect`, {
              type: "PUT",
            })
              .then(() => {
                user.setProperties({
                  redirect_to_wizard: null,
                });
              })
              .catch(popupAjaxError);
          },
        });
      }
    });
  },
};
