use strict;
use warnings;
use Market::MarketData;
use Market::Indicators::Manager;
use Market::Indicators::Liquidity;

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

my $mgr = Market::Indicators::Manager->new();
$mgr->register('Liquidity', Market::Indicators::Liquidity->new());
$mgr->recalculate_all($market);

my $liq = $mgr->slice_array('Liquidity', 0, $market->size()-1);
my $eqh = 0;
my $eql = 0;
for my $i (0 .. $#$liq) {
    my $s = $liq->[$i]->{state} // '';
    $eqh++ if $s eq 'eqh';
    $eql++ if $s eq 'eql';
}
print "Liquidity EQH: $eqh, EQL: $eql\n";
