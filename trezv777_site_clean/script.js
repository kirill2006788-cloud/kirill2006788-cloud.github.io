const menuToggle = document.querySelector('.menu-toggle');
const body = document.body;
const siteNav = document.querySelector('.site-nav');
const orderForm = document.querySelector('#order-form');
const success = document.querySelector('.form-success');
const serviceButtons = document.querySelectorAll('[data-service]');
const commentField = document.querySelector('textarea[name="comment"]');
const vacancyModal = document.querySelector('#vacancy-modal');
const vacancyOpeners = document.querySelectorAll('[data-vacancy-open]');
const vacancyClosers = document.querySelectorAll('[data-vacancy-close]');
const vacancyForm = document.querySelector('#vacancy-form');
const vacancySuccess = document.querySelector('.vacancy-success');
const vacancyMultiselects = document.querySelectorAll('[data-multiselect]');
const legalModal = document.querySelector('#legal-modal');
const legalTriggers = document.querySelectorAll('[data-legal-target]');
const legalPanels = document.querySelectorAll('[data-legal-panel]');
const legalClosers = document.querySelectorAll('[data-legal-close]');
const faqDetails = document.querySelectorAll('.faq-list details');
const quickLinks = document.querySelectorAll('[data-quick-link]');
const sitePreloader = document.querySelector('#site-preloader');

const syncModalState = () => {
  const hasOpenModal = (vacancyModal && !vacancyModal.hidden) || (legalModal && !legalModal.hidden);
  body.classList.toggle('modal-open', Boolean(hasOpenModal));
};

if (sitePreloader) {
  body.classList.add('is-loading');

  const hidePreloader = () => {
    sitePreloader.classList.add('is-hidden');
    body.classList.remove('is-loading');
  };

  window.addEventListener('load', () => {
    window.setTimeout(hidePreloader, 980);
  }, { once: true });

  window.setTimeout(hidePreloader, 2600);
}

if (menuToggle && siteNav) {
  menuToggle.addEventListener('click', () => {
    const isOpen = body.classList.toggle('menu-open');
    menuToggle.setAttribute('aria-expanded', String(isOpen));
  });

  siteNav.querySelectorAll('a').forEach((link) => {
    link.addEventListener('click', () => {
      body.classList.remove('menu-open');
      menuToggle.setAttribute('aria-expanded', 'false');
    });
  });
}

serviceButtons.forEach((button) => {
  button.addEventListener('click', () => {
    if (!commentField) {
      return;
    }

    const service = button.getAttribute('data-service');
    if (!service) {
      return;
    }

    const prefix = `Интересует услуга: ${service}. `;
    if (!commentField.value.includes(prefix)) {
      commentField.value = `${prefix}${commentField.value}`.trim();
    }
  });
});

if (orderForm && success) {
  orderForm.addEventListener('submit', (event) => {
    event.preventDefault();
    success.hidden = false;
    orderForm.reset();
  });
}

if (vacancyForm && vacancySuccess) {
  vacancyForm.addEventListener('submit', (event) => {
    event.preventDefault();
    vacancySuccess.hidden = false;
    vacancyForm.reset();
    vacancyMultiselects.forEach((multiselect) => {
      const trigger = multiselect.querySelector('[data-multiselect-trigger]');
      const panel = multiselect.querySelector('[data-multiselect-panel]');
      const output = multiselect.querySelector('[data-categories-output]');
      if (trigger) trigger.textContent = 'Выберите категории';
      if (panel) panel.hidden = true;
      if (output) output.value = '';
      multiselect.classList.remove('is-open');
    });
  });
}

vacancyMultiselects.forEach((multiselect) => {
  const trigger = multiselect.querySelector('[data-multiselect-trigger]');
  const panel = multiselect.querySelector('[data-multiselect-panel]');
  const output = multiselect.querySelector('[data-categories-output]');
  const checkboxes = multiselect.querySelectorAll('input[type="checkbox"]');

  if (!trigger || !panel || !output || !checkboxes.length) {
    return;
  }

  const updateValue = () => {
    const selected = Array.from(checkboxes)
      .filter((checkbox) => checkbox.checked)
      .map((checkbox) => checkbox.value);
    output.value = selected.join(', ');
    trigger.textContent = selected.length ? `Категории: ${selected.join(', ')}` : 'Выберите категории';
  };

  trigger.addEventListener('click', () => {
    const willOpen = panel.hidden;
    vacancyMultiselects.forEach((item) => {
      item.classList.remove('is-open');
      const itemPanel = item.querySelector('[data-multiselect-panel]');
      const itemTrigger = item.querySelector('[data-multiselect-trigger]');
      if (itemPanel) itemPanel.hidden = true;
      if (itemTrigger) itemTrigger.setAttribute('aria-expanded', 'false');
    });
    panel.hidden = !willOpen;
    multiselect.classList.toggle('is-open', willOpen);
    trigger.setAttribute('aria-expanded', String(willOpen));
  });

  checkboxes.forEach((checkbox) => {
    checkbox.addEventListener('change', updateValue);
  });

  updateValue();
});

document.addEventListener('click', (event) => {
  vacancyMultiselects.forEach((multiselect) => {
    if (!multiselect.contains(event.target)) {
      multiselect.classList.remove('is-open');
      const panel = multiselect.querySelector('[data-multiselect-panel]');
      const trigger = multiselect.querySelector('[data-multiselect-trigger]');
      if (panel) panel.hidden = true;
      if (trigger) trigger.setAttribute('aria-expanded', 'false');
    }
  });
});

if (vacancyModal && vacancyOpeners.length) {
  const openVacancyModal = () => {
    vacancyModal.hidden = false;
    body.classList.remove('menu-open');
    if (menuToggle) {
      menuToggle.setAttribute('aria-expanded', 'false');
    }
    syncModalState();
  };

  const closeVacancyModal = () => {
    vacancyModal.hidden = true;
    syncModalState();
  };

  vacancyOpeners.forEach((opener) => {
    opener.addEventListener('click', openVacancyModal);
  });

  vacancyClosers.forEach((closer) => {
    closer.addEventListener('click', closeVacancyModal);
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !vacancyModal.hidden) {
      closeVacancyModal();
    }
  });
}

if (legalModal && legalTriggers.length && legalPanels.length) {
  const openLegalPanel = (target) => {
    legalPanels.forEach((panel) => {
      panel.classList.toggle('is-active', panel.getAttribute('data-legal-panel') === target);
    });
    legalModal.hidden = false;
    syncModalState();
  };

  const closeLegalPanel = () => {
    legalModal.hidden = true;
    syncModalState();
  };

  legalTriggers.forEach((trigger) => {
    trigger.addEventListener('click', () => {
      const target = trigger.getAttribute('data-legal-target');
      if (target) openLegalPanel(target);
    });
  });

  legalClosers.forEach((closer) => {
    closer.addEventListener('click', closeLegalPanel);
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !legalModal.hidden) {
      closeLegalPanel();
    }
  });
}

faqDetails.forEach((detail) => {
  detail.addEventListener('toggle', () => {
    if (detail.open) {
      detail.classList.add('faq-opened');
      window.setTimeout(() => detail.classList.remove('faq-opened'), 320);
    }
  });
});

if (quickLinks.length && 'IntersectionObserver' in window) {
  const quickSections = Array.from(quickLinks)
    .map((link) => {
      const href = link.getAttribute('href');
      if (!href || !href.startsWith('#')) return null;
      const section = document.querySelector(href);
      if (!section) return null;
      return { link, section, href };
    })
    .filter(Boolean);

  const setActiveQuickLink = (href) => {
    quickLinks.forEach((link) => {
      link.classList.toggle('is-active', link.getAttribute('href') === href);
    });
  };

  let quickNavLockUntil = 0;

  if (quickSections.length) {
    quickLinks.forEach((link) => {
      link.addEventListener('click', (event) => {
        const href = link.getAttribute('href');
        if (!href || !href.startsWith('#')) {
          return;
        }
        const target = document.querySelector(href);
        if (!target) {
          return;
        }
        event.preventDefault();
        quickNavLockUntil = window.performance.now() + 900;
        setActiveQuickLink(href);
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    });

    const quickObserver = new IntersectionObserver((entries) => {
      if (window.performance.now() < quickNavLockUntil) {
        return;
      }

      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];

      if (!visible) return;
      const match = quickSections.find((item) => item.section === visible.target);
      if (match) setActiveQuickLink(match.href);
    }, { threshold: [0.25, 0.4, 0.6], rootMargin: '-12% 0px -52% 0px' });

    quickSections.forEach((item) => quickObserver.observe(item.section));
    setActiveQuickLink('#hero');
  }
}

const revealTargets = document.querySelectorAll('[data-reveal]');
if ('IntersectionObserver' in window && revealTargets.length) {
  const revealObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        revealObserver.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -60px 0px' });

  revealTargets.forEach((node) => revealObserver.observe(node));
} else {
  revealTargets.forEach((node) => node.classList.add('is-visible'));
}
