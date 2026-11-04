package com.masters.estudiantil;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(InstaladorPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
