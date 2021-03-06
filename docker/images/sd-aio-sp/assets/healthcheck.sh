#!/bin/bash -e

if [[ ! -v JBOSS_HOME ]]; then
    if [ -f /etc/profile.d/activator.sh ]
    then
        . /etc/profile.d/activator.sh
    else
        exit 1
    fi
fi

wf_pid=$(ps -ef | grep _HPSA_MAIN_PROCESS_ | grep -v grep | awk '{print $2}')
if [[ -z "$wf_pid" ]]; then
    exit 1
fi

state=$($JBOSS_HOME/bin/jboss-cli.sh -c --commands="read-attribute server-state" 2>/dev/null || :)
if [[ $state != running ]]; then
    exit 1
fi

uoc_pid=$(ps -ef | grep UOC2_SERVER | grep -v grep | awk '{print $2}')
if [[ -z "$uoc_pid" ]]; then
    exit 1
fi

exit 0
