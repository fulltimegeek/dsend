#!/bin/bash

# author: Fulltimegeek <fulltimegeek@protonmail.com>
# purpose: Used to send cryptocurrency transactions from local wallet
# dependencies: jq (Command-line JSON processor), bc (An arbitrary precision calculator language)

# these variables are user specific
cli="/usr/share/dash-0.12.0/bin/dash-cli -testnet"   # this should point to the "dash-cli" file
passphrase="test"   # enter your passphrase here (wallet must be encrypted)
is_masternode=1 # set to 1(true) if wallet contains any masternode addresses

# granular variables for transaction creation
max_fee=.25      # this is just a sanity check, the fee should never be higher than this
crumb_fee=.0001  # cost per 250 bytes of transaction size (tx_fee = min_fee + crumb*(size/250)) @ 1DASH/$2.40= .24cents
minConf=0        # minumum amount of confirmations required to attempt to spend the funds
min_fee=`echo "$crumb_fee * 2" | bc` #message size usually starts around ~250 bytes 

# variables below probably never need to be modified
sending_max=0
loop_interval=60
descriptor_padding=15
re='^[0-9]+$'
receiving_addr=$1   # for readability
sending=$2          # for readability



tag () {
    printf "%${descriptor_padding}s :\t\t%-${descriptor_padding}s = %s\n" "          " $1 $2
}

comment () {
    printf "%${descriptor_padding}s : " "          "
    i=0
    while [ $i -lt $# ]
    do
        printf "%s " $1
        shift    
    done
    echo ""
}

success () {
    color_start="\e[1;34m"
    color_end="\e[m"
    printf "%${descriptor_padding}s :$color_start+$color_end" "          "
    i=0
    while [ $i -lt $# ]
    do
        printf "$color_start%s$color_end " $1
        shift    
    done
    echo ""
}

warning () {
    color_start="\e[1;33m"
    color_end="\e[m"
    printf "$color_start%${descriptor_padding}s$color_end : " "----------"
    i=0
    while [ $i -lt $# ]
    do
        printf "$color_start%s$color_end " $1
        shift    
    done
    echo ""
}

error () {
    color_start="\e[1;31m"
    color_end="\e[m"
    printf "$color_start%${descriptor_padding}s$color_end : " "##########"
    i=0
    while [ $i -lt $# ]
    do
        printf "$color_start%s$color_end " $1
        shift    
    done
    echo ""
}



$cli help &> /dev/null
result=$?
if ! [ $result -eq 0 ]
then
  if [ $result -eq 127 ] 
  then
      error "dash-cli path '$cli' is not valid"
      exit 127
  elif [ $result -eq 1 ]
  then
      error "dashd does not seem to be running."
      exit 1 
  else
      error "$cli returned error $result"
      exit 1
  fi
fi

jq &> /dev/null 
if [ $? -eq 127 ]
then
   error "Dependency 'jq' must be in your path. Example how to install: 'sudo apt-get install jq'"
   exit 201
fi

bc -h &> /dev/null 
if [ $? -eq 127 ]
then
   error "Dependency 'bc' must be in your path. Example how to install: 'sudo apt-get install bc'"
   exit 201
fi


if ! [ $# -eq 2 ]
then
     error "Not enough arguments. Run command as so \"dsend <sending_to_addr> <amount>\""
     exit 202
fi

$cli validateaddress $receiving_addr &> /dev/null
if ! [ $? -eq 0 ]
then
    error $receiving_addr is not a valid address
    exit 203
fi

if [[ ${sending,,} =~ "max" ]]
then
    comment Sending max amount of funds
    sending_max=1
fi


list_tx_inputs () {
    idx=0
    comment listing tx inputs
    tag input_tx $input_tx
    while [ $idx -lt $input_tx ]
    do
        tag tx_$idx ${transaction[$idx]}
        idx=$((idx+1))
    done
}

get_unspent () {
    balance=0 # total money from listunspent ... not including 1000 inputs if is_masternode=1
    added=0 # how many transactions have been added to produce balance

    idx=0
    loop=0
    unspent=`$cli listunspent $minConf 2> /dev/null`
    if ! [ $? -eq 0 ]
    then
        error Failed to list unspent error:$?
        exit 1
    fi
    while [ $loop = 0 ]
    do
	accepted=0
        result=`echo "$unspent" | jq '[.[] | {txid: .txid,vout: .vout,amount: .amount, address: .address, script: .scriptPubKey}]' | jq ".[${idx}]"`
        idx=$((idx+1))
        if [ "$result" = "null" ]; then
    	    loop=1
        else
	    v_txid=`echo "$result" | jq '.txid'`
	    v_vout=`echo "$result" | jq '.vout'`
	    v_amount=`echo $result | jq '.amount'`
	    v_address=`echo $result | jq '.address'`
            v_script=`echo $result | jq '.script'`
	    if  ! [[ $v_amount =~ $re ]]  # checking if v_amount has any decimal points
	    then
	       accepted=1
            elif [ "$is_masternode" -eq 1 ]
               then
                  if ! [ "$v_amount" -eq 1000 ];
                  then
                     accepted=1
                  fi
            else
               accepted=1
            fi

            if [ $accepted -eq 1 ]
            then
	        txid[$added]=$v_txid
                vout[$added]=$v_vout
		amount[$added]=$v_amount
                address[$added]=$v_address
                script[$added]=$v_script
		transaction_size[$added]=`$cli getrawtransaction ${v_txid//\"/} | wc | awk '{print $3}' 2> /dev/null`
                if ! [ $? -eq 0 ]
                then
                    error Failed to get raw transaction error:$?
                    exit 1
                fi
                transaction[$added]="{\"txid\":$v_txid,\"vout\":$v_vout,\"address\":$v_address,\"scriptPubKey\":$v_script,\"amount\":$v_amount}"
	        balance=`echo $balance + $v_amount | bc`
                added=$((added+1))
            fi
        fi 
    done
}

show_unspent () {
    shown=0
    while [ $shown -lt $added ]
    do
       printf "%s | %3d | %s\n" ${txid[$shown]} ${vout[$shown]} ${amount[$shown]}
        shown=$((shown+1))
    done	
}

create_transaction () {
    input_tx=0
    tx_handling=0
    sending=$2
    glitch_min=".001"   # for some reason I had a wallet that didn't want to send funds unless it had .001 left over. 
                        # So, I added this glitch-hack. Not sure what the problem was.
    disposable=`echo "$balance - $min_fee - $glitch_min" | bc`
    if (( $(echo "$disposable <= 0" | bc -l) ))
    then
	error No funds available
        tx=
        return 2
    fi
    if [ $sending_max -eq 1 ]
    then
        sending=`echo $disposable | bc`
    fi

    tag balance $balance
    tag disposable $disposable

    tx=\[
    if (( $(echo "$sending > $disposable" | bc -l) ))
    then
         tag sending $sending
         error Insufficient funds.
         tx=
    else
	 change_addr=`$cli getnewaddress 2> /dev/null`
         if ! [ $? -eq 0 ]
         then
             error Failed to get new address error:$?
              exit 1
         fi
	 while (( $(echo "$tx_handling-$min_fee-$glitch_min < $sending" | bc -l) ))
         do
               if ! (( $(echo "$tx_handling == 0" | bc -l) )) #checking if I need to add comma
               then
                   tx=${tx},
               fi
               tx=${tx}${transaction[$input_tx]}
               tx_handling=`echo $tx_handling + ${amount[$input_tx]} | bc`
               input_tx=$((input_tx+1))
         done
         tx=${tx}\]
         tag input_tx $input_tx
         tag tx_handling $tx_handling
         tag sending $sending
         #Since we don't know how big the tx will be until it's created lets create a dummy
         change=.001 #just some random number for mock transaction
	 raw_transaction=`$cli createrawtransaction $tx \{\"$1\":$sending\,\"$change_addr\":$change\}`
	 raw_tx_size=`echo $raw_transaction | wc | awk '{ print $3 }'`
	 fee=`echo "$min_fee+($crumb_fee*($raw_tx_size/250))" | bc`
	 tag fee $fee
         change=`echo $tx_handling-$fee-$sending | bc`
	 if (( $(echo "$change<=0" | bc -l) ))
	 then
    	     raw_transaction=`$cli createrawtransaction $tx \{\"$1\":$sending} 2> /dev/null`
         else
             raw_transaction=`$cli createrawtransaction $tx \{\"$1\":$sending,\"$change_addr\":$change\} 2> /dev/null`
             tag change $change
             tag change_addr $change_addr
         fi
         if ! [ $? -eq 0 ]
         then
             error Failed to create transaction error:$?
             exit 2
         fi
         tag raw_tx_size "$raw_tx_size(bytes)"
         if (( $(echo "$sending+$fee > $tx_handling" | bc -l) ))
         then
             old_fee=$fee
             fee=`echo "$tx_handling-$sending" | bc`
             warning The fee of $old_fee must be reduced to $fee
         fi
	 if (( $(echo "$fee >= $max_fee" | bc) ))
         then
             error Fee should never be higher than $max_fee \($fee\)
             exit 1
         fi
    fi
}

get_privs () {
    idx=0
    priv_str=\[
    comment "Acquiring necessary private keys..."
    $cli walletpassphrase "$passphrase" 2 2> /dev/null
    if ! [ $? -eq 0 ]
    then
        error "Failed to unlock wallet. Wallet must be encrypted and passphrase needs to be correct."
        exit 4
    fi
    while [ $idx -lt $input_tx ]
    do
        tx=${transaction[$idx]}
        address=`echo "$tx" | jq '.address'`
        priv[$idx]=`$cli dumpprivkey ${address//\"/}`
        if ! [ $idx -eq 0 ]
        then
            priv_str=$priv_str,
        fi
        priv_str=${priv_str}\"${priv[$idx]}\"
        idx=$((idx+1))
    done
    priv_str=$priv_str\]
    
    
    
}

sign_transaction () {
    get_privs
    comment Signing transaction...
    signed_transaction=`$cli signrawtransaction $1 \[$tx\] $priv_str `
    if  ! [ $? -eq 0 ]
    then
        error Failed to sign transaction error:$?
        exit 3
    fi 
    signed_transaction_hex=`echo $signed_transaction | jq '.hex' 2> /dev/null`
    signed_transaction=${signed_transaction_hex//\"/}
}

send_transaction () {
    comment Sending raw transaction...
    created_tx=`$cli sendrawtransaction $1 2>/dev/null`
    comment TXID $created_tx
    if  [ -z $created_tx ]
    then
           error Failed to send transaction error:$?
            exit 10
    else
        success Transaction sent
    fi
}

#while true
#do
    comment Retrieving unspent inputs...
    get_unspent
    comment Creating transaction...
    create_transaction $receiving_addr $sending
    if  ! [ -z $tx ]
    then
        sign_transaction $raw_transaction
        send_transaction $signed_transaction
    fi
    #sleep $loop_interval
#done

