require 'spec_helper'
require 'json'
require 'tempfile'

describe MetadataJsonDeps do
  def with_module_metadata(module_name, module_version, &block)
    Tempfile.create(['puppet-module', '.json']) do |f|
      mod = {
        "name": "puppet-dummy",
        "author": "Nobody",
        "license": "none",
        "source": "/dev/null",
        "summary": "Dummy",
        "version": "0.0.1",
        "dependencies": [
          {
            "name": module_name,
            "version_requirement": module_version,
          },
        ],
      }
      f.write(mod.to_json)
      f.flush
      block.call(f.path)
    end
  end
  context 'no filenames' do
    subject { described_class.run([]) }

    it { expect { subject }.to_not output.to_stdout }
    it { expect { subject }.to_not output.to_stderr }
  end

  describe '.check' do
    context 'no filenames' do
      it { expect(described_class.check([])).to eq([]) }
    end

    context 'with a deprecated module with replacement' do
      subject do
        with_module_metadata('puppetlabs/mssql', '>= 0') { |path| described_class.check([path]) }
      end

      it 'returns deprecated status with superseded_by' do
        dep = subject.first[:dependencies].first
        expect(dep[:status]).to eq(:deprecated)
        expect(dep[:superseded_by]).to eq('puppetlabs-sqlserver')
        expect(dep[:name]).to eq('puppetlabs/mssql')
      end

      it { expect(subject.first[:exit_code]).to eq(2) }
    end

    context 'with a deprecated module without replacement' do
      subject do
        with_module_metadata('puppetlabs/dsc', '>= 0') { |path| described_class.check([path]) }
      end

      it 'returns deprecated status with deprecated_for' do
        dep = subject.first[:dependencies].first
        expect(dep[:status]).to eq(:deprecated)
        expect(dep[:deprecated_for]).to match(/Migrate to/)
      end

      it { expect(subject.first[:exit_code]).to eq(2) }
    end

    context 'with a current dependency' do
      subject do
        with_module_metadata('puppetlabs/stdlib', '>= 0') { |path| described_class.check([path]) }
      end

      it 'returns ok status with current_release' do
        dep = subject.first[:dependencies].first
        expect(dep[:status]).to eq(:ok)
        expect(dep[:current_release]).to match(/\d+\.\d+\.\d+/)
      end

      it { expect(subject.first[:exit_code]).to eq(0) }
    end

    context 'with an outdated dependency' do
      subject do
        with_module_metadata('theforeman/motd', '< 0.1.0') { |path| described_class.check([path]) }
      end

      it 'returns outdated status with current_release' do
        dep = subject.first[:dependencies].first
        expect(dep[:status]).to eq(:outdated)
        expect(dep[:current_release]).to match(/\d+\.\d+\.\d+/)
      end

      it { expect(subject.first[:exit_code]).to eq(1) }
    end
  end

  context 'with a module' do
    subject do
      with_module_metadata(module_name, module_version) { |path| described_class.run([path]) }
    end

    let(:module_version) { '>= 0' }

    context 'that depends on a deprecated module' do
      context 'with replacement' do
        let(:module_name) { 'puppetlabs/mssql' }

        it { expect { subject }.to output(%r{\AChecking .+puppet-module.+\.json\n  puppetlabs/mssql was superseded by puppetlabs-sqlserver\Z}).to_stdout }
        it { expect { subject }.to_not output.to_stderr }
      end

      context 'without replacement' do
        context 'with reason' do
          let(:module_name) { 'puppetlabs/dsc' }

          it { expect { subject }.to output(%r{\AChecking .+puppet-module.+\.json\n  puppetlabs/dsc was deprecated: Migrate to https://forge\.puppet\.com/dsc modules\Z}).to_stdout }
          it { expect { subject }.to_not output.to_stderr }
        end

        # TODO find a module without a reason
        #context 'without reason' do
        #end
      end
    end

    context 'with current dependencies' do
      let(:module_name) { 'puppetlabs/stdlib' }

      it { expect { subject }.to output(%r{\AChecking .+puppet-module.+json\Z}).to_stdout }
      it { expect { subject }.to_not output.to_stderr }
    end

    context 'with an outdated dependency' do
      let(:module_name) { 'theforeman/motd' }
      let(:module_version) { '< 0.1.0' }

      it { expect { subject }.to output(%r{\AChecking .+puppet-module.+json\n  theforeman/motd \(< 0\.1\.0\) doesn't match \d+\.\d+\.\d+\Z}).to_stdout }
      it { expect { subject }.to_not output.to_stderr }
    end
  end

  describe '.bump_dependency' do
    subject do
      Tempfile.create(['puppet-module', '.json']) do |f|
        mod = {
          "name": "puppet-dummy",
          "author": "Nobody",
          "license": "none",
          "source": "/dev/null",
          "summary": "Dummy",
          "version": "0.0.1",
          "dependencies": [
            {
              "name": "puppetlabs-stdlib",
              "version_requirement": ">= 4.25.1 < 8.0.0",
            },
            {
              "name": "puppet/extlib",
              "version_requirement": ">= 2.0.0 < 6.0.0",
            },
          ],
        }
        f.write(mod.to_json)
        f.flush

        described_class.bump_dependency(f.path, module_name, upper_bound)
      end
    end

    context 'with a module using a dash' do
      let(:module_name) { 'puppetlabs-stdlib' }

      context 'passing a matching version' do
        let(:upper_bound) { '8.0.0' }

        it { is_expected.to eq(['>= 4.25.1 < 8.0.0', '>= 4.25.1 < 8.0.0']) }
      end

      context 'passing a new upper bound' do
        let(:upper_bound) { '9.0.0' }

        it { is_expected.to eq(['>= 4.25.1 < 8.0.0', '>= 4.25.1 < 9.0.0']) }
      end
    end

    context 'with a module using a slash' do
      let(:module_name) { 'puppet/extlib' }

      context 'passing a matching version' do
        let(:upper_bound) { '6.0.0' }

        it { is_expected.to eq(['>= 2.0.0 < 6.0.0', '>= 2.0.0 < 6.0.0']) }
      end

      context 'passing a new upper bound' do
        let(:upper_bound) { '7.0.0' }

        it { is_expected.to eq(['>= 2.0.0 < 6.0.0', '>= 2.0.0 < 7.0.0']) }
      end
    end

    context 'with a module not in dependencies' do
      let(:module_name) { 'puppet/example' }
      let(:upper_bound) { '42' }

      it { expect { subject }.to raise_error('Dependency puppet/example not found') }
    end
  end
end
