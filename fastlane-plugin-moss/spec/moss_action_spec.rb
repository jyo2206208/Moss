describe Fastlane::Actions::MossAction do
  describe '#run' do
    it 'prints a message' do
      expect(Fastlane::UI).to receive(:message).with("The moss plugin is working!")

      Fastlane::Actions::MossAction.run(nil)
    end
  end
end
