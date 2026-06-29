#!/usr/bin/env python3
# Scanner cible: routine de gestion d'annuaire GB Camera.
# Vecteur d'annuaire = SRAM offset 0x11B2 -> CPU 0xB1B2 (banque SRAM 0 mappee a 0xA000).
import sys

BANK_SIZE = 0x4000

def foff_to_bank_cpu(foff):
    if foff < BANK_SIZE:
        return 0, foff
    return foff // BANK_SIZE, 0x4000 + (foff % BANK_SIZE)

# Adresses CPU interessantes (SRAM bank0 mappee a 0xA000)
INTEREST = {
    0xB1B2: "directory vector (0x11B2)",
    0xB1D0: "Magic primary (0x11D0)",
    0xB1D5: "checksum sum (0x11D5)",
    0xB1D6: "checksum xor (0x11D6)",
    0xB1D7: "echo block (0x11D7)",
    0xB0D2: "Magic echo (0x10D2)",
    0xB000: "block2 base (0x1000)",
    0xA000: "SRAM base (0x0000)",
}

# opcodes a 3 octets qui chargent un imm16 (op, mnemonic template)
LD16 = {
    0x01: "LD BC,${:04X}", 0x11: "LD DE,${:04X}", 0x21: "LD HL,${:04X}",
    0x31: "LD SP,${:04X}", 0xFA: "LD A,(${:04X})", 0xEA: "LD (${:04X}),A",
    0x08: "LD (${:04X}),SP",
    0xC3: "JP ${:04X}", 0xCD: "CALL ${:04X}",
    0xC2:"JP NZ,${:04X}",0xCA:"JP Z,${:04X}",0xD2:"JP NC,${:04X}",0xDA:"JP C,${:04X}",
    0xC4:"CALL NZ,${:04X}",0xCC:"CALL Z,${:04X}",0xD4:"CALL NC,${:04X}",0xDC:"CALL C,${:04X}",
}

def scan(path):
    rom = open(path,"rb").read()
    print(f"\n########## {path}  ({len(rom)} bytes, {len(rom)//BANK_SIZE} banks) ##########")

    # 1) imm16 references to interesting CPU addresses
    print("\n--- References imm16 vers adresses d'annuaire/checksum ---")
    hits16 = []
    for i in range(len(rom)-2):
        val = rom[i+1] | (rom[i+2]<<8)
        if val in INTEREST:
            op = rom[i]
            bank, cpu = foff_to_bank_cpu(i)
            mnem = LD16.get(op, None)
            txt = mnem.format(val) if mnem else f"?? op={op:02X} imm=${val:04X}"
            hits16.append((bank,cpu,i,op,val,txt))
            print(f"  bank ${bank:02X} cpu ${cpu:04X} (foff ${i:06X})  {txt:24s} -> {INTEREST[val]}")
    if not hits16:
        print("  (aucune)")

    # 2) Strong signal: 21 B2 B1 = LD HL,$B1B2
    print("\n--- LD HL,$B1B2 (21 B2 B1) exact ---")
    pat = bytes([0x21,0xB2,0xB1])
    idx = rom.find(pat)
    found=False
    while idx!=-1:
        found=True
        bank,cpu = foff_to_bank_cpu(idx)
        print(f"  bank ${bank:02X} cpu ${cpu:04X} (foff ${idx:06X})")
        idx = rom.find(pat, idx+1)
    if not found: print("  (aucune)")

    # 3) CP $FF (FE FF) count + cross-ref proximity to any B1?? ref
    cpff = [i for i in range(len(rom)-1) if rom[i]==0xFE and rom[i+1]==0xFF]
    print(f"\n--- CP $FF (FE FF): {len(cpff)} occurrences au total (trop pour lister) ---")

    return rom, hits16, cpff

# Mini desassembleur LR35902 (suffisant pour lire le contexte)
OPC = {
0x00:("NOP",1),0x10:("STOP",2),0x76:("HALT",1),0xF3:("DI",1),0xFB:("EI",1),
0x2A:("LD A,(HL+)",1),0x3A:("LD A,(HL-)",1),0x22:("LD (HL+),A",1),0x32:("LD (HL-),A",1),
0x0A:("LD A,(BC)",1),0x1A:("LD A,(DE)",1),0x02:("LD (BC),A",1),0x12:("LD (DE),A",1),
0x07:("RLCA",1),0x0F:("RRCA",1),0x17:("RLA",1),0x1F:("RRA",1),
0x27:("DAA",1),0x2F:("CPL",1),0x37:("SCF",1),0x3F:("CCF",1),
0xC9:("RET",1),0xD9:("RETI",1),0xC0:("RET NZ",1),0xC8:("RET Z",1),0xD0:("RET NC",1),0xD8:("RET C",1),
0xE9:("JP HL",1),0xF9:("LD SP,HL",1),
0x03:("INC BC",1),0x13:("INC DE",1),0x23:("INC HL",1),0x33:("INC SP",1),
0x0B:("DEC BC",1),0x1B:("DEC DE",1),0x2B:("DEC HL",1),0x3B:("DEC SP",1),
0x09:("ADD HL,BC",1),0x19:("ADD HL,DE",1),0x29:("ADD HL,HL",1),0x39:("ADD HL,SP",1),
0xE2:("LD (C),A",1),0xF2:("LD A,(C)",1),
}
# remplir INC/DEC r, LD r,r etc grossierement
R8=["B","C","D","E","H","L","(HL)","A"]
def dis(rom, start, n):
    # desassemble n octets a partir de l'offset fichier start (CPU addr derive)
    out=[]
    i=start; end=start+n
    bank,base_cpu = foff_to_bank_cpu(start)
    while i<end:
        cpu = foff_to_bank_cpu(i)[1]
        op=rom[i]
        if op in LD16:
            val=rom[i+1]|(rom[i+2]<<8)
            out.append((cpu,f"{LD16[op].format(val)}",3)); i+=3; continue
        if op in OPC:
            m,l=OPC[op]
            if l==2:
                out.append((cpu,f"{m} (imm ${rom[i+1]:02X})",2)); i+=2
            else:
                out.append((cpu,m,1)); i+=1
            continue
        # LD r,imm8 : 0x06,0x0E,0x16,0x1E,0x26,0x2E,0x36,0x3E
        if op in (0x06,0x0E,0x16,0x1E,0x26,0x2E,0x36,0x3E):
            r=R8[(op>>3)&7]; out.append((cpu,f"LD {r},${rom[i+1]:02X}",2)); i+=2; continue
        # ALU A,imm8: C6 CE D6 DE E6 EE F6 FE
        if op in (0xC6,0xCE,0xD6,0xDE,0xE6,0xEE,0xF6,0xFE):
            alu=["ADD A,","ADC A,","SUB ","SBC A,","AND ","XOR ","OR ","CP "][(op>>3)&7]
            out.append((cpu,f"{alu}${rom[i+1]:02X}",2)); i+=2; continue
        # JR e8: 18; JR cc,e8: 20 28 30 38
        if op==0x18 or op in (0x20,0x28,0x30,0x38):
            e=rom[i+1]; e = e-256 if e>127 else e; tgt=cpu+2+e
            cc={0x18:"",0x20:"NZ,",0x28:"Z,",0x30:"NC,",0x38:"C,"}[op]
            out.append((cpu,f"JR {cc}${tgt:04X}",2)); i+=2; continue
        # INC r 04 0C 14...; DEC r 05 0D...
        if op&0xC7==0x04: r=R8[(op>>3)&7]; out.append((cpu,f"INC {r}",1)); i+=1; continue
        if op&0xC7==0x05: r=R8[(op>>3)&7]; out.append((cpu,f"DEC {r}",1)); i+=1; continue
        # LD r,r' 0x40-0x7F (sauf 0x76 halt)
        if 0x40<=op<=0x7F:
            d=R8[(op>>3)&7]; s=R8[op&7]; out.append((cpu,f"LD {d},{s}",1)); i+=1; continue
        # ALU A,r 0x80-0xBF
        if 0x80<=op<=0xBF:
            alu=["ADD A,","ADC A,","SUB ","SBC A,","AND ","XOR ","OR ","CP "][(op>>3)&7]
            out.append((cpu,f"{alu}{R8[op&7]}",1)); i+=1; continue
        # CB prefix
        if op==0xCB:
            cb=rom[i+1]; out.append((cpu,f"CB ${cb:02X}",2)); i+=2; continue
        # PUSH/POP C1 C5 D1 D5 E1 E5 F1 F5
        if op in (0xC1,0xC5,0xD1,0xD5,0xE1,0xE5,0xF1,0xF5):
            rr=["BC","DE","HL","AF"][(op>>4)-0xC]; act="PUSH" if op&0xF==5 else "POP"
            out.append((cpu,f"{act} {rr}",1)); i+=1; continue
        # RST
        if op&0xC7==0xC7: out.append((cpu,f"RST ${op&0x38:02X}",1)); i+=1; continue
        out.append((cpu,f".db ${op:02X}",1)); i+=1
    return out, bank

if __name__=="__main__":
    for p in sys.argv[1:]:
        scan(p)
