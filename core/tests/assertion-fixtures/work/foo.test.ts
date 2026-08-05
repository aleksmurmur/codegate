it('does not throw', () => {
  expect(() => render(<Foo />)).not.toThrow();
});
it('renders the title', () => {
  expect(screen.getByText('hi')).toBeInTheDocument();
});
it('computes', () => {
  expect(sum(1, 2)).toEqual(3);
});
