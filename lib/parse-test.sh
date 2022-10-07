
parse_test_deps()
{
    # DISABLE variable checks for test eval, to print propper errors
    set +u

    #export ktest_crashdump
    export KTEST_TEST_LIB="$ktest_dir/lib/ktest/test-libs.sh"
    eval $("$ktest_test" deps)

    parse_arch "$ktest_arch"

    if [ -z "$ktest_mem" ]; then
	echo "test must specify config-mem"
	exit 1
    fi

    if [ -z "$ktest_timeout" ]; then
	ktest_timeout=6000
    fi

    ktest_tests=$("$ktest_test" list-tests)
    ktest_tests=$(echo $ktest_tests)

    if [[ -z $ktest_tests ]]; then
	echo "No tests found"
	echo "TEST FAILED"
	exit 1
    fi

    local t

    # Ensure specified tests exist:
    if [[ -n $ktest_testargs ]]; then
	for t in $ktest_testargs; do
	    if ! echo "$ktest_tests"|grep -wq "$t"; then
		echo "Test $t not found"
		exit 1
	    fi
	done

	ktest_tests="$ktest_testargs"
    fi

    # ENABLE variable chesk
    set -u
}
