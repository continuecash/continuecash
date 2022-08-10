
function grid2price_256(grid) {
	var X = [
		1048576-1048576,
		1051419-1048576,
		1054270-1048576,
		1057128-1048576,
		1059994-1048576,
		1062868-1048576,
		1065750-1048576,
		1068639-1048576,
		1071537-1048576,
		1074442-1048576,
		1077355-1048576,
		1080276-1048576,
		1083205-1048576,
		1086142-1048576,
		1089087-1048576,
		1092040-1048576]

	var Y = [
		65536 -65536,
		68438 -65536,
		71468 -65536,
		74632 -65536,
		77936 -65536,
		81386 -65536,
		84990 -65536,
		88752 -65536,
		92682 -65536,
		96785 -65536,
		101070-65536,
		105545-65536,
		110218-65536,
		115098-65536,
		120194-65536,
		125515-65536]
	var head = Math.floor(grid/256)
	var tail = grid%256
	var x = X[tail%16]
	var y = Y[Math.floor(tail/16)]
	var beforeShift = ((1<<20)+x) * ((1<<16)+y)
	return beforeShift*Math.pow(2, head)
}


function grid2price_64(grid) {
	var X = [
		524288-524288,
		529997-524288,
		535768-524288,
		541603-524288,
		547500-524288,
		553462-524288,
		559489-524288,
		565581-524288]

	var Y = [
		65536 -65536,
		71468 -65536,
		77936 -65536,
		84990 -65536,
		92682 -65536,
		101070-65536,
		110218-65536,
		120194-65536]
	var head = Math.floor(grid/64)
	var tail = grid%64
	var x = X[tail%8]
	var y = Y[Math.floor(tail/8)]
	var beforeShift = ((1<<19)+x) * ((1<<16)+y)
	return beforeShift*Math.pow(2, head)
}

function price2grid_256(price) {
	var a, b, c;
	for(a=0; a<50; a++) {
		if(grid2price_256(a*256) > price) {
			break;
		}
	}
	a--;
	for(b=0; b<16; b++) {
		if(grid2price_256(a*256+b*16) > price) {
			break;
		}
	}
	b--;
	for(c=0; c<16; c++) {
		if(grid2price_256(a*256+b*16+c) > price) {
			break;
		}
	}
	c--;
	return a*256+b*16+c
}

function price2grid_64(price) {
	var a, b, c;
	for(a=0; a<50; a++) {
		if(grid2price_64(a*64) > price) {
			break;
		}
	}
	a--;
	for(b=0; b<8; b++) {
		if(grid2price_64(a*64+b*8) > price) {
			break;
		}
	}
	b--;
	for(c=0; c<8; c++) {
		if(grid2price_64(a*64+b*8+c) > price) {
			break;
		}
	}
	c--;
	return a*64+b*8+c
}

function test_1a() {
	var last = grid2price_256(0)
	for(var i=1; i<25600; i++) {
		var curr = grid2price_256(i)
		var r = curr/last
		if(r<1.0027 || r> 1.00272) {
			console.log("Error:", i, curr, curr/last)
		}
		last = curr
	}
}

function test_1b() {
	for(var i=1; i<5220; i++) {
		var curr = grid2price_256(i)
		var j = price2grid_256(curr)
		var k = price2grid_256(curr*1.001)
		if(i!=j || i!=k) {
			console.log("Error:", i, j, k, curr)
		}
	}
}

function test_2a() {
	var last = grid2price_64(0)
	for(var i=1; i<6400; i++) {
		var curr = grid2price_64(i)
		var r = curr/last
		if(r<1.01086 || r> 1.0109) {
			console.log("Error:", i, curr, curr/last)
		}
		last = curr
	}
}

function test_2b() {
	for(var i=1; i<3100; i++) {
		var curr = grid2price_64(i)
		var j = price2grid_64(curr)
		var k = price2grid_64(curr*1.005)
		if(i!=j || i!=k) {
			console.log("Error:", i, j, k, curr)
		}
	}
}

test_1a()
test_1b()
test_2a()
test_2b()
