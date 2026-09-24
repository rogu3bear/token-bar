// One animation per disclosure. A new intent starts at the visible height;
// an old completion can never commit a superseded open/close request.
const controllers = new WeakMap();

export function setDisclosureOpen(element, open) {
  const controller = controllers.get(element);
  if (controller) controller.settle(open);
  else element.open = open;
}

export function enhanceDisclosure(element, { media, resizeTarget, style }) {
  const summary = element.querySelector('summary');
  const content = element.querySelector('[data-disclosure-content]');
  let desired = element.open;
  let animation = null;
  function cancel() {
    const previous = animation;
    animation = null;
    previous?.cancel();
    element.classList.remove('is-animating');
  }
  function intent(open) {
    desired = open;
    element.dataset.expanded = String(open);
    summary.setAttribute('aria-expanded', String(open));
    content.inert = !open;
  }
  function settle(open = desired) {
    cancel();
    intent(open);
    element.open = open;
  }
  function toggle(event) {
    event.preventDefault();
    const open = !desired;
    if (media.matches || !element.animate) { settle(open); return; }
    const from = element.getBoundingClientRect().height;
    cancel();
    intent(open);
    element.open = true;
    const to = open ? element.getBoundingClientRect().height : summary.getBoundingClientRect().height;
    if (Math.abs(from - to) < 1) { settle(open); return; }
    element.classList.add('is-animating');
    const next = element.animate([{ height: `${from}px` }, { height: `${to}px` }], {
      duration: parseFloat(style.getPropertyValue('--motion-disclosure')) || 240,
      easing: style.getPropertyValue('--motion-ease').trim() || 'ease-out',
    });
    animation = next;
    next.onfinish = () => { if (animation === next) settle(desired); };
  }
  settle();
  summary.addEventListener('click', toggle);
  media.addEventListener('change', () => settle());
  resizeTarget.addEventListener('resize', () => settle());
  const controller = { settle };
  controllers.set(element, controller);
  return controller;
}
