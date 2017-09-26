{ pkgs }:

# Functions for executing benchmarks on different hardware groups,
# collecting results by parsing logs and converting them to CSV and
# generating reports using Rmarkdown.

let
  testing = import ./testing.nix { inherit pkgs; };
  software = import ./software.nix { inherit pkgs; };
in rec {
  /* Execute a benchmark named as specified using `name` parameter,
     repeated as many times as the integer `times`.

     `toCSV` function is mandatory. It's called using the resulting
     benchmark derivation and returns a bash snippet. The function
     should parse the log in ${drv}/log.txt and set `score` variable
     providing the benchmark value. It should then call `writeCSV`
     function to generate the CSV line.

     `meta` attribute includes information needed at CSV generation time.

     The rest of the attributes are specified in testing.nix:`mkSnabbTest`
  */
  mkSnabbBenchTest = { name, times, toCSV, ... }@attrs:
    let
      # patch needed for Snabb v2016.05 and lower
      testEnvPatch = pkgs.fetchurl {
        url = "https://github.com/snabbco/snabb/commit/e78b8b2d567dc54cad5f2eb2bbb9aadc0e34b4c3.patch";
        sha256 = "1nwkj5n5hm2gg14dfmnn538jnkps10hlldav3bwrgqvf5i63srwl";
      };
      snabbBenchmark = num:
        let
          name' = "${name}_num=${toString num}";
        in {
          ${name'} = pkgs.lib.hydraJob (testing.mkSnabbTest ({
            name = name';
            alwaysSucceed = true;
            patchPhase = ''
              patch -p1 < ${testEnvPatch} || true
            '';
            preInstall = ''
              cp qemu*.log $out/ || true
              cp snabb*.log $out/ || true
            '';
            meta = {
              snabbVersion = attrs.snabb.version or "";
              qemuVersion = attrs.qemu.version or "";
              kernelVersion = attrs.kPackages.kernel.version or "";
              dpdkVersion = attrs.dpdk.version or "";
              repeatNum = num;
              inherit toCSV;
            } // (attrs.meta or {});
          } // removeAttrs attrs [ "times" "toCSV" "dpdk" "kPackages" "meta" "name"]));
        };
    in testing.mergeAttrsMap snabbBenchmark (pkgs.lib.range 1 times);

  /* Execute `basic1` benchmark.

     `basic1` has no dependencies except Snabb,
     being a minimal configuration for a benchmark.    
  */
  mkBenchBasic = { snabb, times, hardware ? "murren", ... }:
    mkSnabbBenchTest {
      name = "basic1_snabb=${testing.versionToAttribute snabb.version or ""}_packets=100e6";
      inherit snabb times hardware;
      checkPhase = ''
        /var/setuid-wrappers/sudo ${snabb}/bin/snabb snabbmark basic1 100e6 |& tee $out/log.txt
      '';
      toCSV = drv: ''
        score=$(awk '/Mpps/ {print $(NF-1)}' < ${drv}/log.txt)
        ${writeCSV drv "basic" "Mpps"}
      '';
    };

  /* Execute `packetblaster` benchmark.

    `packetblaster` sets "lugano" as default hardware group,
    as the benchmark depends on having a NIC installed.
  */
  mkBenchPacketblaster = { snabb, times, hardware ? "lugano", ... }:
    mkSnabbBenchTest {
      name = "${testing.versionToAttribute snabb.version or ""}-packetblaster-64";
      inherit snabb times hardware;
      toCSV = drv: ''
        pps=$(cat ${drv}/log.txt | grep TXDGPC | cut -f 3 | sed s/,//g)
        score=$(echo "scale=2; $pps / 1000000" | bc)
        ${writeCSV drv "blast" "Mpps"}
      '';
      checkPhase = ''
        cd src
        /var/setuid-wrappers/sudo ${snabb}/bin/snabb packetblaster replay --duration 1 \
          program/snabbnfv/test_fixtures/pcap/64.pcap "$SNABB_PCI_INTEL0" |& tee $out/log.txt
      '';
    };

  /* Execute `packetblaster-synth` benchmark.

    Similar to `packetblaster` benchmark, but use "synth"
    command with size 64.
  */
  mkBenchPacketblasterSynth = { snabb, times, ... }:
    mkSnabbBenchTest {
      name = "${testing.versionToAttribute snabb.version or ""}-packetblaster-synth-64";
      inherit snabb times;
      hardware = "lugano";
      toCSV = drv: ''
        pps=$(cat ${drv}/log.txt | grep TXDGPC | cut -f 3 | sed s/,//g)
        score=$(echo "scale=2; $pps / 1000000" | bc)
        ${writeCSV drv "blastsynth" "Mpps"}
      '';
      checkPhase = ''
        /var/setuid-wrappers/sudo ${snabb}/bin/snabb packetblaster synth \
          --src 11:11:11:11:11:11 --dst 22:22:22:22:22:22 --sizes 64 \
          --duration 1 "$SNABB_PCI_INTEL0" |& tee $out/log.txt
      '';
    };


  /* Execute `iperf` benchmark.

     Requires `testNixEnv` built fixtures providing qemu images.

     If hardware group doesn't use have a NIC, ports can be specified.
  */
  mkBenchNFVIperf = { snabb, times, qemu, kPackages, conf ? "NA", hardware ? "lugano", testNixEnv, ... }:
    let
      iperfports = {
        base         = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/same_vlan.ports";
        filter       = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/filter.ports";
        ipsec        = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/crypto.ports";
        l2tpv3       = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/tunnel.ports";
        l2tpv3_ipsec = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/crypto-tunnel.ports";
      };
    in mkSnabbBenchTest {
      name = "iperf_conf=${conf}_snabb=${testing.versionToAttribute snabb.version or ""}_kernel=${testing.versionToAttribute kPackages.kernel.version}_qemu=${testing.versionToAttribute qemu.version}";
      inherit hardware kPackages snabb times qemu testNixEnv;
      toCSV = drv: ''
        score=$(awk '/^IPERF-/ { print $2 }' < ${drv}/log.txt)
        ${writeCSV drv "iperf" "Gbps"}
      '';
      meta = { inherit conf; };
      needsNixTestEnv = true;
      SNABB_IPERF_BENCH_CONF = iperfports.${conf} or "";
      checkPhase = ''
        cd src
        /var/setuid-wrappers/sudo -E program/snabbnfv/selftest.sh bench |& tee $out/log.txt
      '';
    };

  /* Execute `l2fwd/dpdk` benchmark.

     Requires `testNixEnv` built fixtures providing qemu images.

     If hardware group doesn't use have a NIC then conf and pktsize are required
  */
  mkBenchNFVDPDK = { snabb, qemu, kPackages, dpdk, hardware ? "lugano", times, pktsize ? "", conf ? "", testNixEnv, ... }:
    let
      dpdkports = {
        base  = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/snabbnfv-bench.port";
        nomrg = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/snabbnfv-bench-no-mrg_rxbuf.port";
        noind = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/snabbnfv-bench-no-indirect_desc.port";
      };
    in
    # there is no reason to run this benchmark on multiple kernels
    # 3.18 kernel must be used for older dpdks
    if (pkgs.lib.substring 0 4 (kPackages.kernel.version) != "3.18")
    then []
    else mkSnabbBenchTest rec {
      name = "l2fwd_pktsize=${pktsize}_conf=${conf}_snabb=${testing.versionToAttribute snabb.version or ""}_dpdk=${testing.versionToAttribute dpdk.version}_qemu=${testing.versionToAttribute qemu.version}";
      inherit snabb qemu times hardware dpdk kPackages testNixEnv;
      needsNixTestEnv = true;
      toCSV = drv: ''
        score=$(awk '/^Rate\(Mpps\):/ { print $2 }' < ${drv}/log.txt)
        ${writeCSV drv "l2fwd" "Mpps"}
      '';
      meta = { inherit pktsize conf; };
      checkPhase = 
        if hardware == "murren"
        then ''
          cd src

          export SNABB_PACKET_SIZES=${pktsize}
          export SNABB_DPDK_BENCH_CONF=${dpdkports.${conf}}
          /var/setuid-wrappers/sudo -E timeout 120 program/snabbnfv/dpdk_bench.sh |& tee $out/log.txt
        '' else ''
          cd src
          /var/setuid-wrappers/sudo -E timeout 120 program/snabbnfv/packetblaster_bench.sh |& tee $out/log.txt
        '';
    };

  /* Execute `lwaftr` benchmark.

     `times`: How many times each benchmark is repeated
     `duration`: Number of seconds the benchmark should last
     `mode`: The selected benchmark
     `ipv4PCap`, `ipv6PCap`: The packet capture files to use in benchmarks
     `conf`: What config file to use in snabb/src/program/lwaftr/tests/data/

  */
  mkBenchLWAFTR = { snabb
                  , times
                  , duration ? "10"
                  , mode ? "bare"
                  , ipv4PCap ? "ipv4-0550.pcap"
                  , ipv6PCap ? "ipv6-0550.pcap"
                  , conf ? "icmp_on_fail.conf"
                  , loadTestStep ? "0.2e9"
                  , qemu
                  , ... }:
    # TODO: assert mode
    let
      hardware = {
        bare = "murren";
        nic = "igalia";
        nic_on_a_stick = "igalia";
        virt = "igalia";
      };
      checkPhases = {
        bare = ''
          cd src
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb lwaftr bench \
            --duration ${duration} --hydra --bench-file $out/log.csv \
            program/lwaftr/tests/data/${conf} \
            program/lwaftr/tests/benchdata/${ipv4PCap} \
            program/lwaftr/tests/benchdata/${ipv6PCap} |& tee $out/log.txt
        '';
        # Two processes, each running on their own NUMA node
        nic = ''
          cd src

          # Generate the binding table using 15874 IPv4 public addresses.
          # 6: size of psid-length. 2^6: 64 softwires of 1024 port-size each.
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb lwaftr generate-binding-table \
            --output binding-table.conf 193.5.1.100 15874 fc00::100 fc00:1:2:3:4:5:0:7e 6
          echo "softwire-config {" > preamble.conf
          echo "\
}
external-interface {
   allow-incoming-icmp false;
   error-rate-limiting {
      packets 600000;
   }
   reassembly {
      max-fragments-per-packet 40;
   }
}
internal-interface {
   allow-incoming-icmp false;
   error-rate-limiting {
      packets 600000;
   }
   reassembly {
      max-fragments-per-packet 40;
   }
}
instance {
   device test;
   queue {
      id 0;
      external-interface {
         ip 10.0.1.1;
         mac 02:aa:aa:aa:aa:aa;
         next-hop {
            mac 02:99:99:99:99:99;
         }
      }
      internal-interface {
         ip fc00::100;
         mac 02:aa:aa:aa:aa:aa;
         next-hop {
            mac 02:99:99:99:99:99;
         }
      }
   }
}" > postamble.conf
          cat preamble.conf binding-table.conf postamble.conf > test.conf

          # Generate the data files

          # Generate 63 packets, each matches a different softwire:
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb packetblaster lwaftr \
            --src_mac 02:99:99:99:99:99 --dst_mac 02:aa:aa:aa:aa:aa \
            --b4 fc00:1:2:3:4:5:0:7e,193.5.1.100,1024 --aftr fc00::100 --count 2e4 \
            --pcap lwaftr-traffic.pcap --size 550
          # Filter out IPv4 packets to from-inet-test.pcap:
          tcpdump "ip" -r lwaftr-traffic.pcap -w from-inet-test.pcap
          Filter out IPv6 packets to from-b4-test.pcap:
          tcpdump "ip6" -r lwaftr-traffic.pcap -w from-b4-test.pcap

          # Start the application
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb lwaftr run --cpu=1 \
            --conf test.conf \
            --v4 0000:$SNABB_PCI0_1 \
            --v6 0000:$SNABB_PCI1_1 \
            2>&1 | tee $out/log.txt&
          RUN_PID=$!

          # Generate traffic
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb lwaftr loadtest --cpu=7 \
            --step ${loadTestStep} --hydra --bench-file $out/log.csv \
            from-inet-test.pcap IPv4 IPv6 0000:$SNABB_PCI0_0 \
            from-b4-test.pcap IPv6 IPv4 0000:$SNABB_PCI1_0 | tee $out/loadtest.log
        '';
        # Two processes, each on their own NUMA node, talking via one NIC card
        nic_on_a_stick = ''
          cd src

          # Start the application
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb lwaftr run --cpu=1 \
            --conf program/lwaftr/tests/data/${conf} \
            --on-a-stick 0000:$SNABB_PCI0_1 \
            2>&1 | tee $out/log.txt&
          RUN_PID=$!

          # Generate traffic
          /var/setuid-wrappers/sudo ${snabb}/bin/snabb lwaftr loadtest --cpu=7 \
            --bitrate 10e9 --step ${loadTestStep} --program ramp_up \
            --hydra --bench-file $out/log.csv \
            program/lwaftr/tests/benchdata/${ipv4PCap} ALL ALL 0000:$SNABB_PCI0_0 | tee $out/loadtest.log
        '';
        virt = ''
          export PATH=/var/setuid-wrappers/:$(pwd):$PATH:${pkgs.screen}/bin:${pkgs.iputils}/bin
          mv src/program/lwaftr/virt/lwaftrctl.conf.example src/lwaftrctl.conf
          sed -i "s@~/workspace/snabb@$(pwd)@" src/lwaftrctl.conf
          sed -i "s@KERNEL_PARAMS=@KERNEL_PARAMS=init=/nix/var/nix/profiles/system/init@" src/lwaftrctl.conf
          sed -i "s@SHARED_LOCATION=@SHARED_LOCATION=~/workspace@" src/lwaftrctl.conf
          echo 'export QEMU_ARGS="-initrd ~/.test_env/initrd"' >> src/lwaftrctl.conf
          # Prepare VMs
          mkdir ~/workspace

          # Start host and qemus
          cd src
          program/lwaftr/virt/lwaftrctl start snabbnfv
          program/lwaftr/virt/lwaftrctl start vm

          # Copy over script to run lwaftr inside the guest
          source lwaftrctl.conf

          # Run the benchmark
          sleep 20
          program/lwaftr/virt/lwaftrctl start lwaftr

          # Generate traffic
          /var/setuid-wrappers/sudo numactl -m 1 taskset -c 7 ${snabb}/bin/snabb lwaftr loadtest \
            -s ${loadTestStep} \
            program/lwaftr/tests/benchdata/${ipv4PCap} IPv4 IPv6 0000:$SNABB_PCI0_0 \
            program/lwaftr/tests/benchdata/${ipv6PCap} IPv6 IPv4 0000:$SNABB_PCI1_0 | tee $out/loadtest.log

          # We stop guest snabb for logs to be flushed
          program/lwaftr/virt/lwaftrctl stop lwaftr

          # Copy CSV benchmark result from the guest
          cp ~/workspace/lwaftr-bench.csv $out/log.csv

          program/lwaftr/virt/lwaftrctl stop vm
          program/lwaftr/virt/lwaftrctl stop snabbnfv
          mv ../../qemu0.log .
        '';
      };
    name = "lwaftr_snabb=${testing.versionToAttribute snabb.version or ""}_conf=${conf}";
    in mkSnabbBenchTest ({
      inherit name snabb times;
      hardware = hardware.${mode};
      checkPhase = checkPhases.${mode};
      testNixEnv = testing.mkTestEnv { inherit snabb conf; };
      needsNixTestEnv = mode == "virt";
      postInstall = ''
        kill $RUN_PID || true
        /var/setuid-wrappers/sudo chown $(id -u):$(id -g) $out/log.csv
      '';
      toCSV = drv: ''
        sed '1d' ${drv}/log.csv > csv
        awk -F, '{$1="lwaftr,${mode},${duration},${snabb.version},${conf},${drv.meta.qemuVersion or "NA"},${toString drv.meta.repeatNum}" FS $1;}1' OFS=, csv >> $out/bench.csv
        rm csv
      '';
    } // pkgs.lib.optionalAttrs (mode == "virt") {
      inherit qemu;
      name = "${name}";
    });

  /* Given a benchmark derivation, benchmark name and a unit,
     write a line of the CSV file using all provided benchmark information.
  */
  writeCSV = drv: benchName: unit: ''
    if test -z "$score"; then score="NA"; fi
    echo ${benchName},${drv.meta.pktsize or "NA"},${drv.meta.conf or "NA"},${drv.meta.snabbVersion or "NA"},${drv.meta.kernelVersion or "NA"},${drv.meta.qemuVersion or "NA"},${drv.meta.dpdkVersion or "NA"},${toString drv.meta.repeatNum},$score,${unit} >> $out/bench.csv
  '';

  # Generate CSV out of collection of benchmarking logs
  mkBenchmarkCSV = benchmarkList: columnNames:
    pkgs.stdenv.mkDerivation {
      name = "snabb-report-csv";
      buildInputs = [ pkgs.gawk pkgs.bc ];
      # Build CSV on Hydra localhost to spare time on copying
      requiredSystemFeatures = [ "local" ];
      # TODO: uses writeText until following is merged https://github.com/NixOS/nixpkgs/pull/15803
      builder = pkgs.writeText "csv-builder.sh" ''
        source $stdenv/setup
        mkdir -p $out/nix-support

        echo "${columnNames}" > $out/bench.csv
        ${pkgs.lib.concatMapStringsSep "\n" (drv: drv.meta.toCSV drv) benchmarkList}

        # Make CSV file available via Hydra
        echo "file CSV $out/bench.csv" >> $out/nix-support/hydra-build-products
      '';
    };

  /* Using a generated CSV file, list of benchmarks and a report name,
     generate a report using Rmarkdown.
  */
  mkBenchmarkReport = csv: benchmarksList: reportName:
    pkgs.stdenv.mkDerivation {
      name = "snabb-report";
      buildInputs = with pkgs.rPackages; [ rmarkdown ggplot2 dplyr pkgs.R pkgs.pandoc pkgs.which ];
      # Build reports on Hydra localhost to spare time on copying
      requiredSystemFeatures = [ "local" ];
      # TODO: use writeText until runCommand uses passAsFile (16.09)
      builder = pkgs.writeText "csv-builder.sh" ''
        source $stdenv/setup

        # Store all logs
        mkdir -p $out/nix-support
        ${pkgs.lib.concatMapStringsSep "\n" (drv: "cat ${drv}/log.txt > $out/${drv.name}-${toString drv.meta.repeatNum}.log") benchmarksList}
        tar cfJ logs.tar.xz -C $out .
        mv logs.tar.xz $out/
        echo "file tarball $out/logs.tar.xz" >> $out/nix-support/hydra-build-products

        # Create markdown report
        cp ${../lib/reports + "/${reportName}.Rmd"} ./report.Rmd
        cp ${csv} ./bench.csv
        echo -e "\n"
        cat ./bench.csv
        echo -e "\n"
        cat report.Rmd
        echo "library(rmarkdown); render('report.Rmd')" | R --no-save
        cp report.html $out
        echo "file HTML $out/report.html"  >> $out/nix-support/hydra-build-products
        echo "nix-build out $out" >> $out/nix-support/hydra-build-products
      '';
    };

  # Generate a list of names of available reports in `./lib/reports`
  listReports =
    map (name: pkgs.lib.removeSuffix ".Rmd" name)
      (builtins.attrNames (builtins.readDir ../lib/reports));

  # Returns true if version is a prefix of drv.version
  matchesVersionPrefix = version: drv:
    pkgs.lib.hasPrefix version (pkgs.lib.getVersion drv);

  # Select software collections based on version strings
  selectQemus = versions:
    if versions == []
    then software.qemus
    else pkgs.lib.concatMap (version: pkgs.lib.filter (matchesVersionPrefix version) software.qemus) versions;
  selectDpdks = versions: kPackages:
    if versions == []
    then (software.dpdks kPackages)
    else pkgs.lib.concatMap (version: pkgs.lib.filter (matchesVersionPrefix version) (software.dpdks kPackages)) versions;
  selectKernelPackages = versions:
    if versions == []
    then software.kernelPackages
    else pkgs.lib.concatMap (version: pkgs.lib.filter (kPackages: pkgs.lib.hasPrefix version (pkgs.lib.getVersion kPackages.kernel)) software.kernelPackages) versions;

  # Given a list of names and benchmark inputs/parameters, get benchmarks by their alias and pass them the parameters
  selectBenchmarks = names: params:
    testing.mergeAttrsMap (name: (pkgs.lib.getAttr name benchmarks) params) names;

  # Benchmarks aliases that can be referenced using just a name, i.e. "iperf-filter"
  benchmarks = {
    basic = mkBenchBasic;

    packetblaster = mkBenchPacketblaster;
    packetblaster-synth = mkBenchPacketblasterSynth;

    lwaftr = mkBenchLWAFTR;

    iperf = mkBenchNFVIperf;
    iperf-base = params: mkBenchNFVIperf (params // {conf = "base"; hardware = "murren";});
    iperf-filter = params: mkBenchNFVIperf (params // {conf = "filter"; hardware = "murren";});
    iperf-ipsec = params: mkBenchNFVIperf (params // {conf = "ipsec"; hardware = "murren";});
    iperf-l2tpv3 = params: mkBenchNFVIperf (params // {conf = "l2tpv3"; hardware = "murren";});
    iperf-l2tpv3-ipsec = params: mkBenchNFVIperf (params // {conf = "l2tpv3_ipsec"; hardware = "murren";});

    dpdk = mkBenchNFVDPDK;
    dpdk-soft-base-256 = params: mkBenchNFVDPDK (params // {pktsize = "256"; conf = "base"; hardware = "murren";});
    dpdk-soft-nomrg-256 = params: mkBenchNFVDPDK (params // {pktsize = "256"; conf = "nomrg"; hardware = "murren";});
    dpdk-soft-noind-256 = params: mkBenchNFVDPDK (params // {pktsize = "256"; conf = "noind"; hardware = "murren";});
    dpdk-soft-base-64 = params: mkBenchNFVDPDK (params // {pktsize = "64"; conf = "base"; hardware = "murren";});
    dpdk-soft-nomrg-64 = params: mkBenchNFVDPDK (params // {pktsize = "64"; conf = "nomrg"; hardware = "murren";});
    dpdk-soft-noind-64 = params: mkBenchNFVDPDK (params // {pktsize = "64"; conf = "noind"; hardware = "murren";});
  };
}
