use strict;
use warnings;
use lib '.';
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;

my $market = Market::MarketData->new();
my $csv_file = 'Data/datos.csv';
open(my $fh, '<', $csv_file) or die $!;
my $h = <$fh>;
my $c = 0;
while(my $line = <$fh>) {
    chomp $line;
    my ($ts, $o, $hi, $l, $cl, $v) = split(/,/, $line);
    $market->add_candle({ timestamp=>$ts, open=>$o+0, high=>$hi+0, low=>$l+0, close=>$cl+0, volume=>$v+0 });
    $c++;
}
close($fh);
$market->build_timeframes();

my $mgr = Market::IndicatorManager->new();
$mgr->register('Liquidity', Market::Indicators::Liquidity->new());
$mgr->register('SMC', Market::Indicators::SMC_Structures->new());
$mgr->recalculate_all($market);

my $liq = $mgr->slice_array('Liquidity', 0, $market->size()-1);
my $eqh = 0; my $eql = 0;
for my $i (0 .. $#$liq) {
    my $s = $liq->[$i]->{state} // '';
    $eqh++ if $s eq 'eqh';
    $eql++ if $s eq 'eql';
}
print "Liquidity -> EQH: $eqh, EQL: $eql\n";

my $smc = $mgr->slice_array('SMC', 0, $market->size()-1);
my $seqh = 0; my $seql = 0;
for my $i (0 .. $#$smc) {
    $seqh += scalar(@{$smc->[$i]->{eq_highs} // []});
    $seql += scalar(@{$smc->[$i]->{eq_lows}  // []});
}
print "SMC -> EQH: $seqh, EQL: $seql\n";
