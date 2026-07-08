export function addPasswordToggle(input: HTMLInputElement): void {
  const wrapper = document.createElement('div');
  wrapper.className = 'relative';
  input.parentNode!.insertBefore(wrapper, input);
  wrapper.appendChild(input);
  input.classList.add('pr-20');

  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'Afficher';
  button.className =
    'absolute right-2 top-1/2 -translate-y-1/2 text-xs font-semibold text-blue-900 underline';
  wrapper.appendChild(button);

  button.addEventListener('click', () => {
    const isPassword = input.type === 'password';
    input.type = isPassword ? 'text' : 'password';
    button.textContent = isPassword ? 'Masquer' : 'Afficher';
  });
}
