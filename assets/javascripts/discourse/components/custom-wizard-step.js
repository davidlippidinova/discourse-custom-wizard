import Component from "@ember/component";
import { alias, not, or } from "@ember/object/computed";
import { schedule } from "@ember/runloop";
import { htmlSafe } from "@ember/template";
import $ from "jquery";
import { cook } from "discourse/lib/text";
import getUrl from "discourse-common/lib/get-url";
import discourseLater from "discourse-common/lib/later";
import discourseComputed, { observes } from "discourse-common/utils/decorators";
import CustomWizard, {
  updateCachedWizard,
} from "discourse/plugins/discourse-custom-wizard/discourse/models/custom-wizard";
import { wizardComposerEdtiorEventPrefix } from "./custom-wizard-composer-editor";

const uploadStartedEventKeys = ["upload-started"];
const uploadEndedEventKeys = [
  "upload-success",
  "upload-error",
  "upload-cancelled",
  "uploads-cancelled",
  "uploads-aborted",
  "all-uploads-complete",
];

export default Component.extend({
  classNameBindings: [":wizard-step", "step.id"],
  saving: null,

  init() {
    this._super(...arguments);
    this.set("stylingDropdown", {});
  },

  didReceiveAttrs() {
    this._super(...arguments);

    cook(this.step.translatedTitle).then((cookedTitle) => {
      this.set("cookedTitle", cookedTitle);
    });
    cook(this.step.translatedDescription).then((cookedDescription) => {
      this.set("cookedDescription", cookedDescription);
    });

    uploadStartedEventKeys.forEach((key) => {
      this.appEvents.on(`${wizardComposerEdtiorEventPrefix}:${key}`, () => {
        this.set("uploading", true);
      });
    });
    uploadEndedEventKeys.forEach((key) => {
      this.appEvents.on(`${wizardComposerEdtiorEventPrefix}:${key}`, () => {
        this.set("uploading", false);
      });
    });
  },

  didInsertElement() {
    this._super(...arguments);
    this.autoFocus();
  },

  @discourseComputed("step.index", "wizard.required")
  showQuitButton: (index, required) => index === 0 && !required,

  showNextButton: not("step.final"),
  showDoneButton: alias("step.final"),
  btnsDisabled: or("saving", "uploading"),

  @discourseComputed(
    "step.index",
    "step.displayIndex",
    "wizard.totalSteps",
    "wizard.completed"
  )
  showFinishButton: (index, displayIndex, total, completed) => {
    return index !== 0 && displayIndex !== total && completed;
  },

  @discourseComputed("step.index")
  showBackButton: (index) => index > 0,

  @discourseComputed("step.banner")
  bannerImage(src) {
    if (!src) {
      return;
    }
    return getUrl(src);
  },

  @discourseComputed("step.id")
  bannerAndDescriptionClass(id) {
    return `wizard-banner-and-description wizard-banner-and-description-${id}`;
  },

  @discourseComputed("step.fields.[]")
  primaryButtonIndex(fields) {
    return fields.length + 1;
  },

  @discourseComputed("step.fields.[]")
  secondaryButtonIndex(fields) {
    return fields.length + 2;
  },

  @observes("step.id")
  _stepChanged() {
    this.set("saving", false);
    this.autoFocus();
    this._scrollToTop();
  },

  _scrollToTop() {
    // The Discourse route already calls scrollTop() once on `didTransition`,
    // but several things happen *after* that and end up scrolling the page
    // back down:
    //   - the composer editor mounts and focuses its textarea, which makes
    //     the browser scroll the focused element into view;
    //   - other wizard fields with `autofocus` do the same once rendered;
    //   - async work (cooked title/description, preview iframe) changes the
    //     layout height a few hundred ms later.
    //
    // To make the new step always start at the top we:
    //   1. swallow any focus-driven scroll for a short time window after the
    //      step change by re-pinning the scroll position on every `scroll`
    //      and `focus` event;
    //   2. perform several explicit scroll-to-top passes at increasing
    //      delays, so we win against anything that scrolls asynchronously.
    const doScroll = () => {
      window.scrollTo({ top: 0, left: 0, behavior: "auto" });
      const main = document.querySelector("#main-outlet, .wizard-column");
      if (main) {
        main.scrollTop = 0;
      }
    };

    const pin = () => doScroll();
    const onFocusIn = () => {
      // Run after the browser has applied its own scroll-on-focus.
      window.requestAnimationFrame(doScroll);
    };

    window.addEventListener("scroll", pin, { passive: true });
    document.addEventListener("focusin", onFocusIn, true);

    schedule("afterRender", doScroll);
    [0, 50, 150, 350, 700].forEach((delay) => discourseLater(doScroll, delay));

    // After ~800ms the new step is fully painted and any pending async
    // focus/layout work is done: stop pinning so the user can scroll
    // normally again.
    discourseLater(() => {
      window.removeEventListener("scroll", pin);
      document.removeEventListener("focusin", onFocusIn, true);
    }, 800);
  },

  @observes("step.message")
  _handleMessage: function () {
    const message = this.get("step.message");
    this.showMessage(message);
  },

  @discourseComputed("step.index", "wizard.totalSteps")
  barStyle(displayIndex, totalSteps) {
    let ratio = parseFloat(displayIndex) / parseFloat(totalSteps - 1);
    if (ratio < 0) {
      ratio = 0;
    }
    if (ratio > 1) {
      ratio = 1;
    }

    return htmlSafe(`width: ${ratio * 200}px`);
  },

  @discourseComputed("step.fields")
  includeSidebar(fields) {
    return !!fields.findBy("show_in_sidebar");
  },

  autoFocus() {
    discourseLater(() => {
      schedule("afterRender", () => {
        if ($(".invalid .wizard-focusable").length) {
          this.animateInvalidFields();
        }
      });
    });
  },

  animateInvalidFields() {
    schedule("afterRender", () => {
      let $invalid = $(".invalid .wizard-focusable");
      if ($invalid.length) {
        $([document.documentElement, document.body]).animate(
          {
            scrollTop: $invalid.offset().top - 200,
          },
          400
        );
      }
    });
  },

  advance() {
    this.set("saving", true);
    this.get("step")
      .save()
      .then((response) => {
        updateCachedWizard(CustomWizard.build(response["wizard"]));

        if (response["final"]) {
          CustomWizard.finished(response);
        } else {
          this.goNext(response);
        }
      })
      .catch(() => this.animateInvalidFields())
      .finally(() => this.set("saving", false));
  },

  actions: {
    quit() {
      this.get("wizard").skip();
    },

    done() {
      this.send("nextStep");
    },

    showMessage(message) {
      this.showMessage(message);
    },

    stylingDropdownChanged(id, value) {
      this.set("stylingDropdown", { id, value });
    },

    exitEarly() {
      const step = this.step;
      step.validate();

      if (step.get("valid")) {
        this.set("saving", true);

        step
          .save()
          .then(() => this.send("quit"))
          .finally(() => this.set("saving", false));
      } else {
        this.autoFocus();
      }
    },

    backStep() {
      if (this.saving) {
        return;
      }

      this.goBack();
    },

    nextStep() {
      if (this.saving) {
        return;
      }

      this.step.validate();

      if (this.step.get("valid")) {
        this.advance();
      } else {
        this.autoFocus();
      }
    },
  },
});
