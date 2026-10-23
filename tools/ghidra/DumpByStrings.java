// Decompile every function that references one of the target strings and dump to a file.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.data.*;
import java.io.*;
import java.util.*;

public class DumpByStrings extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args.length > 0 ? args[0] : "decomp.txt";
        String[] targets = {
            "CDevG5KB::FindHIDDevice", "CDevG5KB::ApplySetting", "AccessData: SetFeature nErr", "AccessData CRC err",
            "AccessData: GetFeature Failed", "SideLED: mode=", "FillCfg_LowDaly", "SetLedRgbTab failed", "GetLedRgbTab failed",
            "SetLED failed", "GetLED failed", "SetMatrix(%d) Error", "SetMatrix Err, layer", "SetOnBoard failed, nOnBoard",
            "keyinfo_to_hardware_code", "Invaild keycode, Layer=", "SyncCfg: FW Version", "GetPassword failed",
            "CDevG5KB::ReadPower failed", "Psd unmatch: cfg=", "SetGIFParam failed", "GetGame failed", "SendSelfData failed",
            "Reset failed", "GetOnline failed", "LedOpt%d", "LedMask", "SleepHW", "DefLedIndex", "MatrixLen", "ShowDebounce",
            "nKeyDirty=0x%x, nMacroNum", "Macro data: (total size", "GetRealData failed", "SetRealData failed",
            "Set real data failed", "Set music real data failed"
        };
        Memory mem = currentProgram.getMemory();
        Listing listing = currentProgram.getListing();
        ReferenceManager rm = currentProgram.getReferenceManager();
        DecompInterface ifc = new DecompInterface();
        DecompileOptions opts = new DecompileOptions();
        ifc.setOptions(opts);
        ifc.openProgram(currentProgram);
        Set<Address> done = new HashSet<>();
        PrintWriter out = new PrintWriter(new FileWriter(outPath));
        for (String t : targets) {
            for (int enc = 0; enc < 2; enc++) {
                byte[] pat;
                if (enc == 0) pat = t.getBytes("US-ASCII");
                else pat = t.getBytes("UTF-16LE");
                Address a = mem.findBytes(mem.getMinAddress(), pat, null, true, monitor);
                while (a != null) {
                    out.println("### STRING \"" + t + "\" (" + (enc==0?"ascii":"utf16") + ") at " + a);
                    // references may point at string start; also check containing data
                    Set<Address> refFroms = new HashSet<>();
                    for (Reference r : rm.getReferencesTo(a)) refFroms.add(r.getFromAddress());
                    Data d = listing.getDataContaining(a);
                    if (d != null) for (Reference r : rm.getReferencesTo(d.getAddress())) refFroms.add(r.getFromAddress());
                    for (Address from : refFroms) {
                        Function f = listing.getFunctionContaining(from);
                        if (f == null) { out.println("  ref from " + from + " (no function)"); continue; }
                        out.println("  ref from " + from + " in " + f.getName() + " @ " + f.getEntryPoint());
                        if (done.contains(f.getEntryPoint())) continue;
                        done.add(f.getEntryPoint());
                        DecompileResults res = ifc.decompileFunction(f, 120, monitor);
                        out.println("==== FUNCTION " + f.getName() + " @ " + f.getEntryPoint() + " (triggered by \"" + t + "\")");
                        if (res != null && res.getDecompiledFunction() != null) out.println(res.getDecompiledFunction().getC());
                        else out.println("  <decompile failed>");
                        out.println();
                    }
                    Address next = a.add(1);
                    a = mem.findBytes(next, pat, null, true, monitor);
                }
            }
            out.flush();
        }
        out.close();
        ifc.dispose();
        println("done -> " + outPath);
    }
}
