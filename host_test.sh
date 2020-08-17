#!/bin/bash

shopt -s extglob

logfile=out

DEFAULT_QUARKUS_APP_JAR="/home/ashutosh/quarkusRestCrudDemo.orig/quarkus/target/rest-http-crud-quarkus-1.0.0.Alpha1-SNAPSHOT-runner.jar"
DEFAULT_QUARKUS_APP_NATIVE="/home/ashutosh/quarkusRestCrudDemo.orig/quarkus/target/rest-http-crud-quarkus-1.0.0.Alpha1-SNAPSHOT-runner"
CRIU_HOME="/home/ashutosh/quarkus_startup"

datediff() {
	local start=$1
	local end=$2

	sec_start=$(date -d "$start" +%s)
	sec_start=${sec_start##+(0)}	# remove leading zeros
	sec_end=$(date -d "$end" +%s)
	sec_end=${sec_end##+(0)}
	secdiff=$(($sec_end - $sec_start))
	#echo "secdiff: ${secdiff}"

	nsec_start=$(date -d "$start" +%N)
	nsec_start=${nsec_start##+(0)}
	nsec_end=$(date -d "$end" +%N)
	nsec_end=${nsec_end##+(0)}
	nsecdiff=$(($nsec_end - $nsec_start))
	#echo "nanosecdiff: ${nsecdiff}"

	#printf "sec: %s nanosec: %s\n" $secdiff $nsecdiff
	final=$((($secdiff * 1000) + ($nsecdiff / 1000000)))
	echo "$final"
}

check_env() {
	local cdir=`pwd`

	if [ -z "${JAVA_HOME}" ];
	then
		echo "JAVA_HOME is not set"
		exit 1
	fi
	if [ -z "${CRIU_HOME}" ];
	then
		echo "CRIU_HOME is not set"
		exit 1
	fi
	if [ -z "${QUARKUS_APP_JAR}" ];
	then
		echo "QUARKUS_APP_JAR is not set"
		if [ -f ${DEFAULT_QUARKUS_APP_JAR} ]; then
			echo "Setting QUARKUS_APP_JAR to ${DEFAULT_QUARKUS_APP_JAR}"
			QUARKUS_APP_JAR=${DEFAULT_QUARKUS_APP_JAR}
		else
			exit 1
		fi
	fi
	if [ -z "${QUARKUS_APP_NATIVE}" ];
	then
		echo "QUARKUS_APP_NATIVE is not set"
		if [ -f ${DEFAULT_QUARKUS_APP_NATIVE} ]; then
			echo "Setting QUARKUS_APP_NATIVE to ${DEFAULT_QUARKUS_APP_NATIVE}"
			QUARKUS_APP_NATIVE=${DEFAULT_QUARKUS_APP_NATIVE}
		else
			exit 1
		fi
	fi
}

get_restore_time() {
	restore_time=`/home/ashutosh/criu/crit/crit show stats-restore | grep restore_time | cut -d ':' -f 2 | cut -d ',' -f 1`
	echo "time to restore: " $((${restore_time}/1000))
}

pre() {
	check_env

	rm -fr native_startup openj9_startup native criu openj9 openj9_scc
	mkdir -p native_startup openj9_startup native criu openj9 openj9_scc

<< COMMENT
	echo -n "Removing scc..."
	${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,destroyAll &> /dev/null
	echo "Done"

	echo -n "Creating scc..."
	${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xmx128m -Xms128m -jar ${QUARKUS_APP_JAR} &> scc_logs &
	sleep 5s
	numactl --physcpubind="16-31" --membind="1" ./wrk --threads=40 --connections=40 -d60s http://127.0.0.1:8080/fruits
	numactl --physcpubind="16-31" --membind="1" ./wrk --threads=40 --connections=40 -d60s http://127.0.0.1:8080/fruits
	echo "Done"
	sleep 1s
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid: ${pid}"
	kill -9 ${pid} &>/dev/null
COMMENT
}

test_native_startup() {
	logdir="native_startup"

	start=`date +"%T.%3N"`
	numactl --physcpubind="0-3" --membind="0" ${QUARKUS_APP_NATIVE} -Xms100m -Xmn110m -Xmx128m -Dhttp.host=0.0.0.0 &> ${logdir}/${logfile}.${itr} &
	sleep 2s

	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "native pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	startup_time=`grep -o "started in 0\.[0-9]*s" ${logdir}/${logfile}.${itr} | grep -o 0\.[0-9]*`
	startup_time=`echo "scale=0; $startup_time*1000" | bc`
	startup_time=${startup_time%.*}

	echo "native_startup: ${startup_time}"
	native_startup_values+=(${startup_time})
}

test_openj9_startup() {
	logdir="openj9_startup"

	start=`date +"%T.%3N"`
	numactl --physcpubind="0" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,cacheDir=/home/ashutosh/quarkus_startup/.classCache,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xms28m -Xmx28m -Xjit:scratchSpaceLimit=16384,scratchSpaceFactorWhenJSR292Workload=1 -jar ${QUARKUS_APP_JAR} &> ${logdir}/${logfile}.${itr} &
	sleep 2s

	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "native pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	startup_time=`grep -o "started in 0\.[0-9]*s" ${logdir}/${logfile}.${itr} | grep -o 0\.[0-9]*`
	startup_time=`echo "scale=0; $startup_time*1000" | bc`
	startup_time=${startup_time%.*}

	echo "openj9_startup: ${startup_time}"
	openj9_startup_values+=(${startup_time})
}

test_native() {
	logdir="native"

	./hit_url.sh &
	sleep 1s

	start=`date +"%T.%3N"`
	numactl --physcpubind="0-3" --membind="0" ${QUARKUS_APP_NATIVE} -Xms100m -Xmn110m -Xmx128m -Dhttp.host=0.0.0.0 &> ${logdir}/${logfile}.${itr} &
	sleep 2s

	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "native pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	end=`grep "End" ${logdir}/${logfile}.${itr} | head -n 1 | cut -d '=' -f 2`
	echo "Start: ${start} End: ${end}"

	#datediff "09:25:46.982" "09:25:47.009" #${start} ${end}
	printf "native: %s\n" $(datediff ${start} ${end})
	native_values+=($(datediff ${start} ${end}))
}

test_criu_appstart() {
	logdir="criu"
	cdir=`pwd`

	rm -fr checkpoint
	mkdir checkpoint
	pushd checkpoint &>/dev/null

	# numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xmx128m -Xms128m -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	# numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,cacheDir=/home/ashutosh/quarkus_startup/.classCache,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xms128m -Xmx128m -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,cacheDir=/home/ashutosh/quarkus_startup/.classCache,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xms28m -Xmx28m -Xjit:scratchSpaceLimit=16384,scratchSpaceFactorWhenJSR292Workload=1 -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	sleep 5s
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid to dump: ${pid}"
	${CRIU_HOME}/criu-ns dump -t ${pid} -j --tcp-established -v3 -o dump.log

	sleep 1s

	${cdir}/hit_url.sh &
	sleep 1s

	start=`date +"%T.%3N"`
	#echo "start: ${start}"
	numactl --physcpubind="0-3" --membind="0" ${CRIU_HOME}/criu-ns restore -d -j --tcp-established -v3 -o restore.log
	sleep 5s

	get_restore_time
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	end=`grep "End" ${logfile}.${itr} | head -n 1 | cut -d '=' -f 2`
	cp ${logfile}.${itr} ${cdir}/${logdir}
	echo "Start: ${start} End: ${end}"

	printf "criu: %s\n" $(datediff ${start} ${end})

	popd &>/dev/null
	criu_appstart_values+=($(datediff ${start} ${end}))
}

test_criu_response() {
	logdir="criu"
	cdir=`pwd`

	rm -fr checkpoint
	mkdir checkpoint
	pushd checkpoint &>/dev/null

	#numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xmx128m -Xms128m -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	#numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,cacheDir=/home/ashutosh/quarkus_startup/.classCache,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xms128m -Xmx128m -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,cacheDir=/home/ashutosh/quarkus_startup/.classCache,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xms28m -Xmx28m -Xjit:scratchSpaceLimit=16384,scratchSpaceFactorWhenJSR292Workload=1 -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	sleep 5s
	${cdir}/hit_url.sh
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid to dump: ${pid}"
	${CRIU_HOME}/criu-ns dump -t ${pid} -j --tcp-established -v3 -o dump.log

	sleep 1s

	${cdir}/hit_url.sh &
	sleep 1s

	start=`date +"%T.%3N"`
	#echo "start: ${start}"
	numactl --physcpubind="0-3" --membind="0" ${CRIU_HOME}/criu-ns restore -d -j --tcp-established -v3 -o restore.log
	sleep 5s

	# get_restore_time
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	end=`grep "End" ${logfile}.${itr} | head -n 2 | tail -n 1 | cut -d '=' -f 2`
	cp ${logfile}.${itr} ${cdir}/${logdir}
	echo "Start: ${start} End: ${end}"

	printf "criu: %s\n" $(datediff ${start} ${end})

	popd &>/dev/null
	criu_response_values+=($(datediff ${start} ${end}))
}

test_criu_scc() {
	logdir="criu"
	cdir=`pwd`

	rm -fr checkpoint
	mkdir checkpoint
	pushd checkpoint &>/dev/null

	${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xmx128m -Xms128m -jar ${QUARKUS_APP_JAR} </dev/null &>${logfile}.${itr} &
	sleep 5s
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid to dump: ${pid}"
	${CRIU_HOME}/criu-ns dump -t ${pid} -j --tcp-established -v3 -o dump.log

	sleep 1s

	${cdir}/hit_url.sh &
	sleep 1s

	start=`date +"%T.%3N"`
	#echo "start: ${start}"
	${CRIU_HOME}/criu-ns restore -d -j --tcp-established -v3 -o restore.log
	sleep 5s

	# get_restore_time
	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	end=`grep "End" ${logfile}.${itr} | head -n 2 | tail -n 1 | cut -d '=' -f 2`
	cp ${logfile}.${itr} ${cdir}/${logdir}
	echo "Start: ${start} End: ${end}"

	printf "criu: %s\n" $(datediff ${start} ${end})

	popd &>/dev/null
	criu_scc_values+=($(datediff ${start} ${end}))
}

test_openj9() {
	logdir="openj9"

	./hit_url.sh &
	sleep 1s

	start=`date +"%T.%3N"`
	${JAVA_HOME}/bin/java -jar ${QUARKUS_APP_JAR} &> ${logdir}/${logfile}.${itr} &
	sleep 5s

	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	end=`grep "End" ${logdir}/${logfile}.${itr} | head -n 1 | cut -d '=' -f 2`
	echo "Start: ${start} End: ${end}"

	#datediff "09:25:46.982" "09:25:47.009" #${start} ${end}
	printf "openj9: %s\n" $(datediff ${start} ${end})
	openj9_values+=($(datediff ${start} ${end}))
}

test_openj9_scc() {
	logdir="openj9_scc"

	./hit_url.sh &
	sleep 1s

	start=`date +"%T.%3N"`
	# numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xmx128m -Xms128m -jar ${QUARKUS_APP_JAR} &> ${logdir}/${logfile}.${itr} &
	numactl --physcpubind="0-3" --membind="0" ${JAVA_HOME}/bin/java -Xshareclasses:name=quarkus,cacheDir=/home/ashutosh/quarkus_startup/.classCache,readonly -XX:ShareClassesEnableBCI -Xscmx80m -Djava.net.preferIPv4Stack=true -Xms28m -Xmx28m -Xjit:scratchSpaceLimit=16384,scratchSpaceFactorWhenJSR292Workload=1 -jar ${QUARKUS_APP_JAR} </dev/null &>${logdir}/${logfile}.${itr} &
	sleep 5s

	pid=`ps -ef | grep rest-http-crud-quarkus | grep -v grep | awk '{ print $2 }'`
	echo "java pid: ${pid}"
	kill -9 ${pid} &>/dev/null

	end=`grep "End" ${logdir}/${logfile}.${itr} | head -n 1 | cut -d '=' -f 2`
	echo "Start: ${start} End: ${end}"

	#datediff "09:25:46.982" "09:25:47.009" #${start} ${end}
	printf "openj9_scc: %s\n" $(datediff ${start} ${end})
	openj9_scc_values+=($(datediff ${start} ${end}))
}

get_average() {
	arr=("$@")
	#echo "values: ${arr[@]}"
	for val in ${arr[@]}
	do
		sum=$(( $sum + $val ))
	done
	#echo "sum: $sum"
	#echo "count: ${#arr[@]}"
	echo $(( $sum / ${#arr[@]} ))	
}

get_averages() {
	for key in ${headers[@]}
	do
		if [ ${flags[$key]} -eq 1 ]; then
			value_list=(${values[$key]})
			#echo "value_list: ${value_list[@]}"
			#get_average ${value_list[@]}
			averages[$key]=$(get_average ${value_list[@]})
		fi
	done
}

print_summary() {
	echo "########## Summary ##########"
	printf "\t"
	for key in ${headers[@]}
	do
		if [ ${flags[$key]} -eq 1 ]; then
			printf "%-15s" "${key}"
		fi
	done
	echo
	index=0
	for itr in `seq 1 ${iterations}`
	do
		printf "$itr\t"
		for key in ${headers[@]}
		do
			if [ ${flags[$key]} -eq 1 ]; then
				value_list=(${values[$key]})
				printf "%-15s" "${value_list[${index}]}"
			fi
		done
		echo
		index=$(( $index + 1 ))
	done
	printf "Avg\t"
	for key in ${headers[@]}
	do
		if [ ${flags[$key]} -eq 1 ]; then
			printf "%-15s" "${averages[$key]}"
		fi
	done
	echo
}

iterations=40

declare -a headers=("native_startup" "openj9_startup" "native" "criu_appstart" "criu_response" "criu_scc" "openj9" "openj9_scc")
declare -A flags
for key in ${headers[@]}
do
	flags[$key]=0
done
declare -A values
declare -A averages
for key in ${headers[@]}
do
	averages[$key]=0
done

declare -a native_startup_values openj9_startup_values native_values criu_appstart_values criu_response_values criu_scc_values openj9_values openj9_scc_values

# ./start_db.sh
sleep 2s
pre

if [ $# -ne 0 ]; then
	for arg in "$@";
	do
		case "$arg" in
		"native_startup" | "openj9_startup" | "native" | "criu_appstart" | "criu_response" | "criu_scc" | "openj9" | "openj9_scc")
			flags[$arg]=1
			;;
		"all")
			for key in ${headers[@]}
			do
				flags[$key]=1
			done
			;;
		*)
			echo "invalid argument $arg"
			exit 0
			;;
		esac
	done	
else
	for key in "${headers[@]}"
	do
		flags[$key]=1
	done
fi

for itr in `seq 1 ${iterations}`;
do
	for key in ${headers[@]}
	do
		flag=${flags[$key]}
		if [ ${flag} -eq 1 ]; then
			echo "###"
			echo "Iteration ${itr} for ${key}"
			test_${key}
		fi
	done
done

values[native_startup]=${native_startup_values[@]}
values[openj9_startup]=${openj9_startup_values[@]}
values[native]=${native_values[@]}
values[criu_appstart]=${criu_appstart_values[@]}
values[criu_response]=${criu_response_values[@]}
values[criu_scc]=${criu_scc_values[@]}
values[openj9]=${openj9_values[@]}
values[openj9_scc]=${openj9_scc_values[@]}

get_averages
print_summary

# docker stop postgres-quarkus-rest-http-crud

