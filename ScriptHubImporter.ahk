#SingleInstance Force
#NoEnv
SetBatchLines -1 ;Run script at maximum speed

global g_SourceFiles:={}
global g_classList:={}
DDLString:=""
Loop, Files, %A_LineFile%\..\ScriptHubExport*.json
{
	g_SourceFiles[A_LoopFileName]:=A_LoopFilePath
	DDLString:=DDLString ? DDLString . "|" . A_LoopFileName : A_LoopFileName
}

Gui, Add, Text, xm+5 w55, CE Export:
Gui, Add, DropDownList, x+5 w200 vIBM_Import_FileSelect, %DDLString%
Gui, Add, Text, x+10 w40, Revision:
Gui, Add, Edit, x+5 w20 Limit1 vIBM_Import_Revision, A
Gui, Add, Button, xm+140 w100 h30 gIBM_Import_Generate, Generate
Gui, Add, Text, xm+3 w380 r2, A pointer data file must exist with a name in the format Pointers_P11.json, where 11 is the game platform ID for the relevant platform (11 being Steam)
Gui, Add, Text, xm+3 w380 r2, The revision should only be changed from A if different imports need to be generated for the same game version, usually due to the addition of a new field

Gui, Show,,,Briv Master Import Generator
return

GuiClose:
ExitApp

IBM_Import_Generate()
{
	GuiControlGet, fileName,, IBM_Import_FileSelect
	if(!g_SourceFiles.HasKey(fileName))
		return
	filePath:=g_SourceFiles[fileName]
	GuiControlGet, revision,, IBM_Import_Revision
	if(StrLen(revision)==0)
		return
	StartTime:=A_TickCount
	FileRead, fileData, %filePath%
	fullStructureData:=JSON.Load(fileData)
	JSONReadTime:=A_TickCount

	for className,classData in fullStructureData.classes
	{
		cleanClassName:=StrReplace(className,"+",".") ;Subclasses are written with a '+' as separator in the key, e.g. as CrusadersGame.User.ShopItemDef+chestData, which is unhelpful as all other references use the expected '.'
		g_classList[cleanClassName]:=new gameClass(cleanClassName,classData,false,false)
	}
	AddBaseType("System.Int32","Int")
	AddBaseType("System.Boolean","Char")
	AddBaseType("System.String","UTF-16")
	AddBaseType("System.Double","Double")
	AddBaseType("System.Single","Float")
	AddBaseType("System.Int64","Int64")
	AddBaseType("Engine.Numeric.Quad","Quad")
	;AddBaseType("UnityGameEngine.Utilities.ProtectedInt","Int") ;Doesn't appear to be used, needs special handling
	AddBaseType("System.Collections.Generic.List","List",true,"V")
	AddBaseType("System.Collections.Generic.Dictionary","Dict",true,"KV")
	AddBaseType("System.Collections.Generic.HashSet","HashSet",true,"K")
	AddBaseType("System.Collections.Generic.Queue","Queue",true,"V")
	AddBaseType("System.Collections.Generic.Stack","Stack",true,"V")

	for _,classObj in g_classList
	{
		classObj.ProcessLinkages()
	}
	LoadedTime:=A_TickCount
	;Game Details from the JSON
	gameVersionMajor:=g_classList["CrusadersGame.GameSettings"].Fields["MobileClientVersion"].Value
	gameVersionMinor:=g_classList["CrusadersGame.GameSettings"].Fields["VersionPostFix"].Value ;This might be empty, as versions are 638, 638.1, 638.2 etc
	fullVersion:=gameVersionMajor . gameVersionMinor
	gamePlatform:=g_classList["CrusadersGame.GameSettings"].Fields["Platform"].Value ;11 for Steam, 21 for EGS
	;Pointer read
	pointerFilePath:=A_LineFile . "\..\Pointers_P" . gamePlatform . ".json"
	if(FileExist(pointerFilePath))
	{
		FileRead, pointerRaw, % A_LineFile . "\..\Pointers_P" . gamePlatform . ".json"
	}
	else
		OutputDebug % "Could not find pointer file [" . pointerFilePath . "]`n"
	;Export from CE is now loaded, check the files to process
	gameObjectFiles:={}
	matchPattern:="O)^MemoryLocations_(\w+)\.txt$"
	OutputDebug % "+++++++++++++++++++++++++++++++++++++++++++++++++`nStart output`n+++++++++++++++++++++++++++++++++++++++++++++++++`n"
	importDirectory:=A_LineFile . "\..\Offsets_P" . gamePlatform . "_V" . fullVersion . "_" . revision . "\"
	if !InStr(FileExist(importDirectory), "D")
	{
		FileCreateDir, %importDirectory%
		if (ErrorLevel)
			OutputDebug % "Failed to create output directory [" . importDirectory . "]`n"
	}
	Loop, Files, %A_ScriptDir%\Settings_BaseClassTypeList\*.txt
	{
		if(RegExMatch(A_LoopFileName,matchPattern,match))
		{
			OutputDebug % "+++++++++++++++++++++++++++++++++++++++++++++++++`nNew file`n+++++++++++++++++++++++++++++++++++++++++++++++++`n"
			gameObjectName:=match[1]
			outputTree:=ProcessFile(A_LoopFilePath)
			gameObjectFiles[gameObjectName]:=GenerateImportText(outputTree)
			FileDelete, % importDirectory . "IC_" . gameObjectName . "_Import.ahk"
			FileAppend, % gameObjectFiles[gameObjectName], % importDirectory . "IC_" . gameObjectName . "_Import.ahk"
		}
	}
	GameObjectFileTime:=A_TickCount
	offSetOutput:={}
	offSetOutput["Pointers"]:=json.Load(pointerRaw)
	offSetOutput["Imports"]:=gameObjectFiles
	offSetOutput["Pointers","Import_Version_Major"]:=gameVersionMajor+0 ;Try to keep this an Int...
	offSetOutput["Pointers","Import_Version_Minor"]:=gameVersionMinor
	offSetOutput["Pointers","Import_Revision"]:=revision
	offSetOutput["Pointers","Platform"]:=gamePlatform
	pointerFullVersion:=offSetOutput["Pointers","Pointer_Version_Major"] . offSetOutput["Pointers","Pointer_Version_Minor"]
	pointerFileJson:=JSON.dump(offSetOutput["Pointers"],,"`t") ;Use tabs to lay these out for potential human editing
	FileDelete, % importDirectory . "\IC_Offsets.json"
	FileAppend, %pointerFileJson%, % importDirectory . "\IC_Offsets.json"
	offSetOutputJSON:=JSON.dump(offSetOutput)
	zlib:=New IC_BrivMaster_Budget_Zlib_Class()
	compressedJSON:=zlib.Deflate(offSetOutputJSON)
	dataPath:=A_LineFile . "\..\IC_Offsets_Data_P" . gamePlatform . ".zlib"
	FileDelete, %dataPath%
	FileAppend, % compressedJSON, %dataPath%
	headerString:=fullVersion . "," . revision . "," . pointerFullVersion . "," . offSetOutput["Pointers","Pointer_Revision"]
	headerPath:=A_LineFile . "\..\IC_Offsets_Header_P" . gamePlatform . ".csv"
	FileDelete, %headerPath%
	FileAppend, % headerString, %headerPath%

	OutputDebug % "Complete, JSON load time=[" . JSONReadTime-StartTime . "] object read time=[" . LoadedTime-JSONReadTime . "] game object file process time=[" . GameObjectFileTime-LoadedTime . "]`n"
	MSGBOX % "Complete, JSON load time=[" . JSONReadTime-StartTime . "] object read time=[" . LoadedTime-JSONReadTime . "] game object file process time=[" . GameObjectFileTime-LoadedTime . "]`n"
}

GenerateImportText(outputTree)
{
	importText:=""
	for _,baseObject in outputTree
	{
		baseObject.Output(importText)
	}
	return importText
}

;Process a settings file line-by-line.
;Lines starting with '#.' are ignored and are used as comments
;Lines starting with '#!' are for the full class location, the first object on each following line is referenced against this object (in the form this.<val>)
;Lines starting with '#!!' force a collection member to be of a specific type, e.g. in a dictionary of objects of class A, #!! B requires that the member be of class B, where B must inherit from A. This is used to return correct offsets when different inherited classes have the same property at a different offset. This applies only to the next item
ProcessFile(filePath)
{
	currentBaseObject:=""
	currentObject:=""
	currentForcedMember:=""
	outputString:=""
	objectList:={} ;Stores each processed object, with key in the format myObj.Child.Grandchild
	baseObjectList:={}
	Loop Read, %filePath%
	{
		line:=TRIM(A_LoopReadLine)
		if(SubStr(line,1,2)=="#.")
		{
			;Do nothing
		}
		else if(SubStr(line,1,3)=="#!!") ;Must be checked before #! given the that is a substring of this
		{
			className:=Trim(SubStr(line,4))
			if(g_classList.HasKey(className))
				currentForcedMember:=g_classList[className]
			else
				OutputDebug % "Cannot find forced member type [" . className . "]`n"
		}
		else if(SubStr(line,1,2)=="#!")
		{
			className:=Trim(SubStr(line,3))
			if(g_classList.HasKey(className))
			{
				currentBaseObject:=new BaseObject(className,g_classList[className])
				baseObjectList.Push(currentBaseObject)
			}
			else
				OutputDebug % "Cannot find defined base type [" . className . "]`n"
		}
		else
		{
			if(StrLen(line)>0) ;Ignore whitespace
			{
				if(!currentBaseObject)
				{
					OutputDebug % "Attempted to process standard line [" . line . "] without a currentBaseObject`n"
					continue
				}
				;There are 3 cases here
				;1 item - reference against currentBaseObject and output offsets
				;2 items - reference the first against currentBaseObject (if not already present in objectList), output second with offsets from first
				;3+ items - reference the first against currentBaseObject (if not already present in objectList), process item 2 to n-1 with offsets from first, output offsets from last
				objects:=StrSplit(line,".")
				;OutputDebug % "Line: " . line . "`n"
				itemCount:=objects.Count()
				curObjectIndex:=1
				currentToken:=currentBaseObject
				currentPath:="" ;Built as parent.child.grandchild
				while(curObjectIndex<=itemCount)
				{
					currentName:=objects[curObjectIndex]
					parentPath:=currentPath
					currentPath:=currentPath ? currentPath . "." . currentName : currentName
					if(objectList.HasKey(currentPath)) ;Already processed
						currentToken:=objectList[currentPath]
					else
					{
						if(curObjectIndex==itemCount AND currentForcedMember)
						{
							unforcedField:=currentToken.GetField(currentName)
							currentField:=currentForcedMember.GetField(currentName)
							if(unforcedField==currentField)
								OutputDebug % "Forced type applied but [" . currentForcedMember.Name . "] was found for [" . currentToken.Name . "] already (possible due to being the first alphabetically)`n"
							else if(!currentForcedMember.CheckParent(currentToken.Field.Type))
								OutputDebug % "Forced type applied but [" . currentForcedMember.Name . "] is not a child of [" . currentToken.Name . "]`n"
							else
								OutputDebug % "Normal case - Forced type applied to [" . currentForcedMember.Name . "] is child of [" . currentToken.Name . "]`n"

						}
						else
						{
							currentField:=currentToken.GetField(currentName)
						}
						if(currentField)
						{
							newToken:=new OutputToken(currentName,currentField,curObjectIndex==1 ? currentBaseObject : "")
							currentToken.Children.Push(newToken)
							currentToken:=newToken
							objectList[currentPath]:=newToken
						}
						else
						{
							if(curObjectIndex==1)
								OutputDebug % "First item - Unable to find class [" . currentBaseObject.Name . "] member [" . currentName . "]`n"
							else
								OutputDebug % "Middle item - Unable to find class [" . currentObjectReference.Name . "] member [" . currentName . "]`n"
						}
					}
					curObjectIndex++
				}
				currentForcedMember:="" ;Clear as only applies to one item
			}
		}
	}
	return baseObjectList
}

class BaseObject
{
	__new(name,type)
	{
		this.Name:=name
		this.Type:=type
		this.Children:={}
	}

	GetField(name) ;Needed so BaseObject is interchangable with OutputToken (TODO: Set up inheritance?)
	{
		return this.Type.GetField(name)
	}

	Output(byRef importText)
	{
		for _,child in this.Children ;Nothing to actually output for the base object, just iterate children
			child.Output(importText,"this")
	}
}

class OutputToken
{
	__new(name,field,baseItem:="")
	{
		this.Name:=name
		this.Children:={}
		this.ChildCollection:=""
		this.SanitisedName:=this.SanitiseName(name)
		this.Field:=field
		this.Type:=field.Type.Clone() ;Does this need to be .Clone() so changes for the .Field for collections don't change it?
		if(this.Type.IsCollection)
		{
			if(this.Field.CollectionValueType)
			{
				this.Field.Type:=this.Field.CollectionValueType
			}
			else
				OutputDebug % "Using collection without value type [" . currentName . "]`n"
			if(this.Type.ChildCollection) ;If a collection has a child collection it must be inserted into the list as a meta-object
			{
				this.ChildCollection:=new OutputToken(this.Type.ChildCollection.Name,this.Type.ChildCollection)
				;this.Children.Push(this.ChildCollection) ;Don't create a duplicate entry
			}
		}
		this.BaseItem:=baseItem ;The first object in a chain, to be referenced from the base object rather than the (non-existant) previous
	}

	Output(byRef importText, currentString)
	{
		currentString:=this.OutputField(importText,currentString)
		if(this.ChildCollection)
			currentString:=this.ChildCollection.OutputField(importText,currentString)
		for _,child in this.Children
				child.Output(importText,currentString)
	}

	OutputField(byRef importText,currentString)
	{
		if(this.BaseItem)
		{
			importText.=currentString . "." . this.SanitisedName . ":=New GameObjectStructure(this." . this.BaseItem.Name . ",""" . this.Type.GetOutputType() . """," . 	this.Field.GetOffSetString() . ")`n"
		}
		else
		{
			importText.=currentString . "." . this.SanitisedName . ":=New GameObjectStructure(" . currentString . ",""" . this.Type.GetOutputType() . """," . this.Field.GetOffSetString() . ")`n"

		}
		if(this.Type.CollectionHasKey)
			importText.=currentString . "." . this.SanitisedName . "._CollectionKeyType:=""" . this.Field.CollectionKeyTypeName . """`n"
		if(this.Type.CollectionHasValue)
			importText.=currentString . "." . this.SanitisedName . "._CollectionValType:=""" . this.Field.CollectionValueTypeName . """`n"
		currentString.="." . this.SanitisedName ;Must be after as original value used above
		return currentString
	}

	GetField(name) ;Skips to the child collection if present, as it isn't described in the base type list file
	{
		if(this.ChildCollection)
			return this.ChildCollection.GetField(name)
		else
			return this.Field.Type.GetField(name)
	}

	SanitiseName(name) ;AHK does now allow <> in variable names, so those in the form <blah>k__BackingField are changed to blah_k__BackingField
	{
		if(RegExMatch(name,"O)<(.+)>k__BackingField",Matches))
		{
			if(Matches[1]=="<effectKey>") ;This is an exception from Antilectual's python script. Unclear why it is done like this, comment is 'fix for activeEffectKeyHandlers using k_backingfields'
				return "effectKey"
			else
				return Matches[1] . "_k__BackingField"
		}
		else
			return name
	}
}

AddBaseType(typeName,outputType,isCollection:=false,collectionMembers:="")
{
	if(g_classList.HasKey(typeName))
		OutputDebug % "Overwriting loaded type [" . typeName . "] with base version`n"
	classData:={}
	classData.ShortName:=isCollection ? outputType : typeName ;For collections, we want e.g. 'List' as the shortName, as it's used for collections of collections
	g_classList[typeName]:=new gameClass(typeName,classData,true,isCollection)
	if(outputType)
		g_classList[typeName].OutputType:=outputType ;Only valid if IsBaseType is true, this is the type output into imports, e.g. 'System.Boolean' has an OutputType of 'Char'
	if(isCollection)
	{
		g_classList[typeName].CollectionHasKey:=inStr(collectionMembers,"K") ? true : false
		g_classList[typeName].CollectionHasValue:=inStr(collectionMembers,"V") ? true : false
	}
}

class gameClass
{
	__new(name,data,isBaseType,isCollection)
	{
		this.Name:=name
		this.ShortName:=data.ShortName ;TODO: Do we need this for anything?
		this.IsBaseType:=isBaseType ;Type like System.Int32 which we define directly
		this.IsCollection:=isCollection ;Does this contain other classes as members, e.g. a dictionary, list?
		this.ParentName:=this.HandleAbstractClasses(data.Parent)
		this.Parent:={} ;Can only be assigned once all data is read in
		this.Children:={}
		this.Fields:={}
		this.ChildCollection:=""
		this.IsEnum:=this.ParentName=="System.Enum" ;Enums are just ints, and SH GOS expects their type to be this
		for fieldName,fieldData in data.fields
		{
			this.Fields[fieldName]:=new fieldClass(fieldName,fieldData)
		}
	}

	HandleAbstractClasses(parentName) ;CrusadersGame.Effects.BaseActiveEffectKeyHandler`1[CrusadersGame.Effects.EllywickDeckOfManyThingsHandler] becomes CrusadersGame.Effects.BaseActiveEffectKeyHandler`1[T]
	{
		parentName:=StrReplace(parentName,"+",".") ;Subclasses are written with a '+' as separator in the key, e.g. as CrusadersGame.User.ShopItemDef+chestData, which is unhelpful as all other references use the expected '.'. Must be here to align with class name cleaning
		if(RegExMatch(parentName,"O)([^``]+``1)\[.+\]",Matches))
		{
			return Matches[1] . "[T]"
		}
		else
			return parentName
	}

	GetName() ;Applies Enum override, for use when processing collection key/value types
	{
		if(this.IsEnum)
			return "System.Enum"
		else
			return this.Name
	}

	CheckParent(type) ;True if the supplied object is the parent type, checking recursively
	{
		if(type==this.Parent)
			return true
		else if(this.Parent)
			return this.Parent.CheckParent(type)
	}

	GetOutputType()
	{
		if(this.IsEnum)
			return "Int" ;Not System.Enum for some reason - probably just simpler to avoid having to translate it to the underlying Int32 TODO: This begs the question of why we care when it comes to collection members
		else if(this.IsBaseType)
			return this.OutputType
		else
			return "Int" ;Anything that isn't a base type should be a pointer
	}

	ProcessLinkages()
	{
		;Parent
		if(g_classList.HasKey(this.ParentName))
		{
			this.Parent:=g_classList[this.ParentName]
			this.Parent.Children[this.Name]:=this
		}
		else
		{
			if(InStr(this.ParentName,"Effects"))
				OutputDebug % "Failed to find parent class [" . this.ParentName . "] for class [" . this.Name . "]`n"
		}
		;Fields
		for _,field in this.Fields
		{
			field.ProcessLinkages()
		}
	}

	GetField(name,allowParent:=true,allowChildren:=true) ;Returns the field. Searches upwards through classes that this one inherits from if needed
	{
		if(this.Fields.HasKey(name))
			return this.Fields[name]
		curField:=""
		if (allowParent AND this.Parent)
		{
			curField:=this.Parent.GetField(name,true,false) ;Do not allow children to be found from the parent, as they will be different inheritance chains
			if(curField)
					return curField
		}
		if(allowChildren)
		{
			for _,v in this.Children
			{
				curField:=v.GetField(name,false,true) ;Do not allow parents to be found from children, or we'll have a infinite loop
				if(curField)
					return curField
			}
		}
	}
}

class fieldClass
{
	__new(name,data)
	{
		this.Name:=name
		this.Offset:=data.offset
		this.TypeName:=data.type
		this.Type:={} ;Can only be assigned once all data is read in
		this.Value:=data.value ;A few objects have values, notable the game version and platform
		this.CollectionKeyTypeName:=""
		this.CollectionValueTypeName:=""
		this.Static:=data.static
	}

	GetField(name) ;Returns the field. Searches upwards through classes that this one inherits from if needed - Implemented in fieldClass due to the existance of child collections, it will be called on the children potentially
	{
		if(this.Type.HasKey(name))
			return this.Type[name]
		else if (this.TypeParent)
			return this.Type.Parent.GetField(name)
	}

	GetOffSetString() ;Returns the offset, including the static offset if needed
	{
		if(this.Static)
			return "[this.StaticOffset" . (this.Offset ? "+" . this.Offset : "") . "]"
		else
			return "[" . this.Offset . "]"
	}

	ProcessLinkages()
	{
		if(g_classList.HasKey(this.TypeName)) ;Look for base type
			this.Type:=g_classList[this.TypeName]
		else if (!this.ProcessCollection()) ;Check for a collection
		{
			;OutputDebug % "Unable to find type [" . this.TypeName . "] for field [" . this.Name . "]`n"
		}
	}

	FindCollection(typeName,byRef firstElement, byRef secondElement)
	{
		RegExMatch(typeName, "O)^([^<>,]+)<(.*)>$" , Matches) ;dict<K,V>, list<K>, hashSet<V>, but complicated by K or V being able to themselves be a collection, e.g. dict<K<X,Y>,V>.
		if(g_classList[Matches[1]].isCollection)
		{
			type:=g_classList[Matches[1]]
			RegExMatch(Matches[2],"O)([^<>,]+(?:<.*>)?)(?:,([^<>,]+(?:<.*>)?))?",SubMatches) ;Matches[2] will be either K, or K,V, but as above either could be collections, so K<X>, K<X>,V K,V<X>, K<X>,V<Y>
			firstElement:=SubMatches[1]
			secondElement:=SubMatches[2]
			return type
		}
		return false
	}

	ProcessCollection()
	{
		if(colType:=this.FindCollection(this.TypeName,firstElement:="",secondElement:=""))
		{
			this.Type:=colType.Clone() ;Clone is important - allows us to add fields to the new object
			if(colType.CollectionHasKey AND colType.CollectionHasValue) ;Both - dictionary
			{
				if(childType:=this.FindCollection(firstElement,firstElementChild:="",secondElementChild:="")) ;Key - do not create child field
				{
					this.CollectionKeyTypeName:=firstElement
					this.CollectionKeyType:=childType
				}
				else ;Non-collection
				{
					if(g_classList.HasKey(firstElement))
					{
						this.CollectionKeyType:=g_classList[firstElement]
						this.CollectionKeyTypeName:=this.CollectionKeyType.GetName()
					}
					else
					{
						this.CollectionKeyTypeName:=firstElement
						;OutputDebug % "Unable to find dictionary key class [" . firstElement . "] for field [" . this.Name . "]`n"
					}
				}
				if(childType:=this.FindCollection(secondElement,firstElementChild:="",secondElementChild:="")) ;Value, create child field
				{
					this.CollectionValueTypeName:=secondElement
					this.CollectionValueType:=childType
					data:={}
					data.Offset:="" ;No offset, as it's directly in the element of the parent collection
					data.static:=false
					data.type:=secondElement
					this.Type.ChildCollection:=new fieldClass(childType.ShortName,data)
					this.Type.ChildCollection.ProcessLinkages() ;This does some duplicate checks, but should be rare
					this.CollectionValueType:=this.Type.ChildCollection.Type
				}
				else ;Non-collection
				{
					if(g_classList.HasKey(secondElement))
					{
						this.CollectionValueType:=g_classList[secondElement]
						this.Type.Fields:=this.CollectionValueType.Fields ;Give the collection clone the same members as the object
						this.Type.Parent:=this.CollectionValueType.Parent ;This would break inherited collections
						this.CollectionValueTypeName:=this.CollectionValueType.GetName()
					}
					else
					{
						this.CollectionValueTypeName:=secondElement
						;OutputDebug % "Unable to find dictionary value class [" . secondElement . "] for field [" . this.Name . "]`n"
					}
				}
			}
			else if(colType.CollectionHasKey) ;Key only - Hash Set - this actually needs the value (which is the SAME) set too, despite not outputting it TODO: Figure out why ScriptHub is like this. Maybe change this if-else-if chain to use the type name instead of these flags?
			{
				if(childType:=this.FindCollection(firstElement,firstElementChild:="",secondElementChild:="")) ;Key - do not create child field
				{
					this.CollectionKeyTypeName:=firstElement
					this.CollectionKeyType:=childType
				}
				else ;Non-collection
				{
					if(g_classList.HasKey(firstElement))
					{
						this.CollectionKeyType:=g_classList[firstElement]
						this.CollectionKeyTypeName:=this.CollectionKeyType.GetName()
					}
					else
					{
						this.CollectionKeyTypeName:=firstElement
						;OutputDebug % "Unable to find HashSet key class [" . firstElement . "] for field [" . this.Name . "]`n"
					}
				}
				if(childType:=this.FindCollection(firstElement,firstElementChild:="",secondElementChild:="")) ;Value, create child field
				{
					this.CollectionValueTypeName:=firstElement
					this.CollectionValueType:=childType
					data:={}
					data.Offset:="" ;No offset, as it's directly in the element of the parent collection
					data.static:=false
					data.type:=firstElement
					this.Type.ChildCollection:=new fieldClass(childType.ShortName,data)
					this.Type.ChildCollection.ProcessLinkages() ;This does some duplicate checks, but should be rare
					this.CollectionValueType:=this.Type.ChildCollection.Type
				}
				else ;Non-collection
				{
					if(g_classList.HasKey(firstElement))
					{
						this.CollectionValueType:=g_classList[firstElement]
						this.Type.Fields:=this.CollectionValueType.Fields ;Give the collection clone the same members as the object
						this.Type.Parent:=this.CollectionValueType.Parent ;This would break inherited collections
						this.CollectionValueTypeName:=this.CollectionValueType.GetName()
					}
					else
					{
						this.CollectionValueTypeName:=firstElement
						;OutputDebug % "Unable to find HashSet value class [" . firstElement . "] for field [" . this.Name . "]`n"
					}
				}
			}
			else if(colType.CollectionHasValue) ;Value only - List, Queue, Stack
			{
				this.CollectionKeyTypeName:=""
				this.CollectionKeyType:=""
				if(childType:=this.FindCollection(firstElement,firstElementChild:="",secondElementChild:="")) ;Value, create child field
				{
					this.CollectionValueTypeName:=firstElement

					data:={}
					data.Offset:="" ;No offset, as it's directly in the element of the parent collection
					data.static:=false
					data.type:=firstElement
					this.Type.ChildCollection:=new fieldClass(childType.ShortName,data)
					this.Type.ChildCollection.ProcessLinkages() ;This does some duplicate checks, but should be rare
					this.CollectionValueType:=this.Type.ChildCollection.Type
				}
				else ;Non-collection
				{
					if(g_classList.HasKey(firstElement))
					{
						this.CollectionValueType:=g_classList[firstElement]
						this.Type.Fields:=this.CollectionValueType.Fields ;Give the collection clone the same members as the object
						this.Type.Parent:=this.CollectionValueType.Parent ;This would break inherited collections
						this.CollectionValueTypeName:=this.CollectionValueType.GetName()
					}
					else
					{
						this.CollectionValueTypeName:=firstElement
						;OutputDebug % "Unable to find List, Queue or Stack value class [" . firstElement . "] for field [" . this.Name . "]`n"
					}
				}
			}
			else
			{
				OutputDebug % "ProcessCollection() found collection but without keys or values?`n"
			}
			return true
		}
		return false
	}
}

class IC_BrivMaster_Budget_Zlib_Class ;A class for applying z-lib compression. Badly. This is aimed at strings of <100 characters
{
	__New() ;Pre-computes binary values for various things to improve run-time performance
	{
		BASE64_CHARACTERS:="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" ;RFC 4648 S4, base64
		this.BASE64_TABLE:={}
		Loop, Parse, BASE64_CHARACTERS
		{
			this.BASE64_TABLE[this.IntToBinaryString(A_Index-1,6)]:=A_LoopField ;Note: The key gets converted to a decimal number, e.g. "000100" becomes 100 base-10, but the same happens when looking up using a string of 1's and 0's so the lookup still works out. The alternative would be to force to string at both ends, which is likely more internal operations
		}
		this.HOFFMAN_CHARACTER_TABLE:={}
		loop 256
		{
			this.HOFFMAN_CHARACTER_TABLE[A_Index-1]:=this.CodeToBinaryString(A_Index-1)
		}
		this.LENGTH_TABLE:={}
		loop 256
		{
			this.LENGTH_TABLE[A_INDEX+2]:=this.GetLengthCode(A_INDEX+2) ;3 to 258
		}
		this.DISTANCE_TABLE:={}
		loop 64 ;As there are 32K distance values, only pre-calculate the short common ones. Others will be done as needed
		{
			this.DISTANCE_TABLE[A_INDEX]:=this.CalcDistanceCode(A_Index)
		}
	}

	;----------------------------------

	Deflate(inputString,minMatch:=3,maxMatch:=258) ;inputString must fit into a single 32K block. minMatch must be at least 3, and maxMatch must be at most 258
	{
		pos:=1
		inputLength:=StrLen(inputString)
		output:="" ;Note: Accumulating the existing output appears to be a tiny bit faster than not doing so and having more complex string operations
		outputBinary:="00011110" . "01011011" . "110" ;2 bytes of header (LSB first), 3 bits of block header
		while(pos<=inputLength)
		{
			if(inputLength-pos+1>=minMatch) ;If there are enough characters left for a minimum match. +1 is there because the character in the current position is included
			{
				match:=1
				distance:=0
				curLookahead:=minMatch
				while(match AND pos+curLookahead-1<=inputLength AND curLookahead<=maxMatch) ;-1 as the current character is included (i.e. SubStr(haystack,startPosition,3) takes 3 characters starting from position 1, so ends at startPosition+2
				{
					lookAhead:=SubStr(inputString,pos,curLookahead)
					match:=inStr(output,lookAhead,1,0) ;Look for an exact match, looking backwards (right to left). MUST be case-sensitive
					if(match AND pos-match<=32768)
					{
						distance:=pos-match
						lastFoundlookAhead:=lookAhead
						matchLength:=curLookahead ;We can use curLookahead instead of StrLen(lookAhead) as we checked in the while clause that there is enough remaining characters to fill the subStr
					}
					else ;Look for repeats, e.g. if the lookahead is abc, see if the previous characters were abc, if aaa, see if previous character was a
					{
						loop % curLookahead-1 ;An exact match would be covered above
						{
							endChunk:=SubStr(output,-A_Index+1) ;Start of 0 means return last character, -2 means return the last 3 characters
							if(this.StringRepeat(endChunk,curLookahead)==lookAhead)
							{
								match:=A_Index
								distance:=match
								matchLength:=curLookahead
								lastFoundlookAhead:=lookAhead
							}
						}
					}
					curLookahead++
				}
				if(distance) ;3+ char string exists in output buffer
				{
					output.=lastFoundlookAhead
					outputBinary.=this.LENGTH_TABLE[matchLength]
					outputBinary.=this.GetDistanceCode(distance)
					pos+=matchLength
					Continue
				}
			}
			char:=SubStr(inputString,pos,1)
			output.=char
			outputBinary.=this.HOFFMAN_CHARACTER_TABLE[ASC(char)]
			pos++
		}
		outputBinary.="0000000" ;End of block, 256-256=0 as 7 bits, which we might as well hard-code
		while(MOD(StrLen(outputBinary),8)) ;Pad to byte boundry
			outputBinary.="0"
		outputBinary:=this.ReverseByteOrder(outputBinary) ;Reverse prior to adding Adler32
		adler32:=this.Adler32(inputString)
		Loop 32
			outputBinary.=((adler32 >> (32-A_Index)) & 1)
		outputBase64:=this.BinaryStringToBase64(outputBinary)
		return outputBase64
	}

	;----------------------------------

	BinaryStringToBase64(string) ;Requires string to have a length that is a multiple of 8
	{
		pos:=1
		while(pos<StrLen(string))
		{
			slice:=SubStr(string,pos,24) ;Take 24bits at a time
			sliceLen:=StrLen(slice)
			if(sliceLen==24) ;Standard case
			{
				loop, 4
					accu.=this.BASE64_TABLE[SubStr(slice,6*(A_Index-1)+1,6)]
				pos+=24
			}
			else if (sliceLen==16) ;16 bits, need to pad with 2 zeros to reach 18 and be divisible by 3, then add an = to replace the last 6-set
			{
				slice.="00"
				loop, 3
					accu.=this.BASE64_TABLE[SubStr(slice,6*(A_Index-1)+1,6)]
				accu.="="
				Break ;Since we're out of data
			}
			else if (sliceLen==8) ;8 bits, need to pad with 4 zeros to reach 12 and be divisible by 2, then add == to replace the last two 6-sets
			{
				slice.="0000"
				loop, 2
					accu.=this.BASE64_TABLE[SubStr(slice,6*(A_Index-1)+1,6)]
				accu.="=="
				Break ;Since we're out of data
			}
		}
		return accu
	}

	StringRepeat(string,length) ;Repeats string until Length is reached, including partial repeats. Eg string=abc length=5 gives abcab
	{
		loop % Ceil(length/StrLen(string))
			output.=string
		return SubStr(output,1,length)
	}

	Adler32(data) ;Per RFC 1950
	{
		s1:=1
		s2:=0
		Loop Parse, data
		{
			byte:=Asc(A_LoopField)
			s1:=Mod(s1 + byte, 65521)
			s2:=Mod(s2 + s1, 65521)
		}
		return (s2 << 16) | s1
	}

	ReverseByteOrder(string) ;We assemble LSB-first as required for the hoffman encoding, but need to be MSB-first for the Base64 conversion. Requires string to have length that is a multiple of 8. Doing the 8 bits explictly seems fractionally faster than using a loop
	{
		pos:=1
		while(pos<StrLen(string))
		{
			accu.=SubStr(string,pos+7,1)
			accu.=SubStr(string,pos+6,1)
			accu.=SubStr(string,pos+5,1)
			accu.=SubStr(string,pos+4,1)
			accu.=SubStr(string,pos+3,1)
			accu.=SubStr(string,pos+2,1)
			accu.=SubStr(string,pos+1,1)
			accu.=SubStr(string,pos,1)
			pos+=8
		}
		return accu
	}

	GetDistanceCode(distance) ;Uses the lookup table for values up to 64, and calls the calculation of higher distances
	{
		if(distance<=64)
			return this.DISTANCE_TABLE[distance]
		else
			return this.CalcDistanceCode(distance)
	}

	CodeToBinaryString(code) ;Takes an ASCII character code, e.g. "97" for "a" and returns the fixed Hoffman-encouded binary representation as a LSB-first string. Used to pre-calculate the lookup table
	{
		if(code>=0 AND code<=143)
		{
			code+=0x30
			bits:=8
		}
		else if(code>=144 AND code<=255)
		{
			code+=0x100
			bits:=9
		}
		else
			MSGBOX % "Invalid character code"
		return this.IntToBinaryString(code,bits)
	}

	GetLengthCode(length) ;Used to pre-calculate the lookup table
	{
		if(length==3) ;Simple cases, no extra bits
			return "0000001"
		else if(length==4)
			return "0000010"
		else if(length==5)
			return "0000011"
		else if(length==6)
			return "0000100"
		else if(length==7)
			return "0000101"
		else if(length==8)
			return "0000110"
		else if(length==9)
			return "0000111"
		else if(length==10)
			return "0001000"
		else if(length<=12)
			return "0001001" . this.IntToBinaryStringLSB(length-11,1)
		else if(length<=14)
			return "0001010" . this.IntToBinaryStringLSB(length-13,1)
		else if(length<=16)
			return "0001011" . this.IntToBinaryStringLSB(length-15,1)
		else if(length<=18)
			return "0001100" . this.IntToBinaryStringLSB(length-17,1)
		else if(length<=22)
			return "0001101" . this.IntToBinaryStringLSB(length-19,2)
		else if(length<=26)
			return "0001110" . this.IntToBinaryStringLSB(length-23,2)
		else if(length<=30)
			return "0001111" . this.IntToBinaryStringLSB(length-27,2)
		else if(length<=34)
			return "0010000" . this.IntToBinaryStringLSB(length-31,2)
		else if(length<=42)
			return "0010001" . this.IntToBinaryStringLSB(length-35,3)
		else if(length<=50)
			return "0010010" . this.IntToBinaryStringLSB(length-43,3)
		else if(length<=58)
			return "0010011" . this.IntToBinaryStringLSB(length-51,3)
		else if(length<=66)
			return "0010100" . this.IntToBinaryStringLSB(length-59,3)
		else if(length<=82)
			return "0010101" . this.IntToBinaryStringLSB(length-67,4)
		else if(length<=98)
			return "0010110" . this.IntToBinaryStringLSB(length-83,4)
		else if(length<=114)
			return "0010111" . this.IntToBinaryStringLSB(length-99,4)
		else if(length<=130)
			return "11000000" . this.IntToBinaryStringLSB(length-115,4)
		else if(length<=162)
			return "11000001" . this.IntToBinaryStringLSB(length-131,5)
		else if(length<=194)
			return "11000010" . this.IntToBinaryStringLSB(length-163,5)
		else if(length<=226)
			return "11000011" . this.IntToBinaryStringLSB(length-195,5)
		else if(length<=257)
			return "11000100" . this.IntToBinaryStringLSB(length-227,5)
		else if(length==258)
			return "11000101"
	}

	CalcDistanceCode(distance)
	{
		if(distance<=4)
			return this.IntToBinaryString(distance-1,5)
		else if(distance<=6)
			return "00100" . this.IntToBinaryStringLSB(distance-5,1)
		else if(distance<=8)
			return "00101" . this.IntToBinaryStringLSB(distance-7,1)
		else if(distance<=12)
			return "00110" . this.IntToBinaryStringLSB(distance-9,2)
		else if(distance<=16)
			return "00111" . this.IntToBinaryStringLSB(distance-13,2)
		else if(distance<=24)
			return "01000" . this.IntToBinaryStringLSB(distance-17,3)
		else if(distance<=32)
			return "01001" . this.IntToBinaryStringLSB(distance-25,3)
		else if(distance<=48)
			return "01010" . this.IntToBinaryStringLSB(distance-33,4)
		else if(distance<=64)
			return "01011" . this.IntToBinaryStringLSB(distance-49,4)
		else if(distance<=96)
			return "01100" . this.IntToBinaryStringLSB(distance-65,5)
		else if(distance<=128)
			return "01101" . this.IntToBinaryStringLSB(distance-97,5)
		else if(distance<=192)
			return "01110" . this.IntToBinaryStringLSB(distance-129,6)
		else if(distance<=256)
			return "01111" . this.IntToBinaryStringLSB(distance-193,6)
		else if(distance<=384)
			return "10000" . this.IntToBinaryStringLSB(distance-257,7)
		else if(distance<=512)
			return "10001" . this.IntToBinaryStringLSB(distance-385,7)
		else if(distance<=768)
			return "10010" . this.IntToBinaryStringLSB(distance-513,8)
		else if(distance<=1024)
			return "10011" . this.IntToBinaryStringLSB(distance-769,8)
		else if(distance<=1536)
			return "10100" . this.IntToBinaryStringLSB(distance-1025,9)
		else if(distance<=2048)
			return "10101" . this.IntToBinaryStringLSB(distance-1537,9)
		else if(distance<=3072)
			return "10110" . this.IntToBinaryStringLSB(distance-2049,10)
		else if(distance<=4096)
			return "10111" . this.IntToBinaryStringLSB(distance-3073,10)
		else if(distance<=6144)
			return "11000" . this.IntToBinaryStringLSB(distance-4097,11)
		else if(distance<=8192)
			return "11001" . this.IntToBinaryStringLSB(distance-6145,11)
		else if(distance<=12288)
			return "11010" . this.IntToBinaryStringLSB(distance-8193,12)
		else if(distance<=16384)
			return "11011" . this.IntToBinaryStringLSB(distance-12289,12)
		else if(distance<=24576)
			return "11100" . this.IntToBinaryStringLSB(distance-16385,13)
		else if(distance<=32768)
			return "11101" . this.IntToBinaryStringLSB(distance-24577,13)
	}

	IntToBinaryString(code,bits) ;Takes an Int and returns a binary string
	{
		Loop % bits
			bin:=(code >> (A_Index-1)) & 1 . bin
		return bin
	}

	IntToBinaryStringLSB(code,bits) ;Takes an Int and returns a binary string, LSB first
	{
		Loop % bits
			bin:=bin . (code >> (A_Index-1)) & 1
		return bin
	}
}

/**
 * Lib: JSON.ahk
 *     JSON lib for AutoHotkey.
 * Version:
 *     v2.1.3 [updated 04/18/2016 (MM/DD/YYYY)]
 * License:
 *     WTFPL [http://wtfpl.net/]
 * Requirements:
 *     Latest version of AutoHotkey (v1.1+ or v2.0-a+)
 * Installation:
 *     Use #Include JSON.ahk or copy into a function library folder and then
 *     use #Include <JSON>
 * Links:
 *     GitHub:     - https://github.com/cocobelgica/AutoHotkey-JSON
 *     Forum Topic - http://goo.gl/r0zI8t
 *     Email:      - cocobelgica <at> gmail <dot> com
 */


/**
 * Class: JSON
 *     The JSON object contains methods for parsing JSON and converting values
 *     to JSON. Callable - NO; Instantiable - YES; Subclassable - YES;
 *     Nestable(via #Include) - NO.
 * Methods:
 *     Load() - see relevant documentation before method definition header
 *     Dump() - see relevant documentation before method definition header
 */
class JSON
{
	/**
	 * Method: Load
	 *     Parses a JSON string into an AHK value
	 * Syntax:
	 *     value := JSON.Load( text [, reviver ] )
	 * Parameter(s):
	 *     value      [retval] - parsed value
	 *     text    [in, ByRef] - JSON formatted string
	 *     reviver   [in, opt] - function object, similar to JavaScript's
	 *                           JSON.parse() 'reviver' parameter
	 */
	class Load extends JSON.Functor
	{
		Call(self, ByRef text, reviver:="")
		{
			this.rev := IsObject(reviver) ? reviver : false
		; Object keys(and array indices) are temporarily stored in arrays so that
		; we can enumerate them in the order they appear in the document/text instead
		; of alphabetically. Skip if no reviver function is specified.
			this.keys := this.rev ? {} : false

			static quot := Chr(34), bashq := "\" . quot
			     , json_value := quot . "{[01234567890-tfn"
			     , json_value_or_array_closing := quot . "{[]01234567890-tfn"
			     , object_key_or_object_closing := quot . "}"

			key := ""
			is_key := false
			root := {}
			stack := [root]
			next := json_value
			pos := 0

			while ((ch := SubStr(text, ++pos, 1)) != "") {
				if InStr(" `t`r`n", ch)
					continue
				if !InStr(next, ch, 1)
					this.ParseError(next, text, pos)

				holder := stack[1]
				is_array := holder.IsArray

				if InStr(",:", ch) {
					next := (is_key := !is_array && ch == ",") ? quot : json_value

				} else if InStr("}]", ch) {
					ObjRemoveAt(stack, 1)
					next := stack[1]==root ? "" : stack[1].IsArray ? ",]" : ",}"

				} else {
					if InStr("{[", ch) {
					; Check if Array() is overridden and if its return value has
					; the 'IsArray' property. If so, Array() will be called normally,
					; otherwise, use a custom base object for arrays
						static json_array := Func("Array").IsBuiltIn || ![].IsArray ? {IsArray: true} : 0

					; sacrifice readability for minor(actually negligible) performance gain
						(ch == "{")
							? ( is_key := true
							  , value := {}
							  , next := object_key_or_object_closing )
						; ch == "["
							: ( value := json_array ? new json_array : []
							  , next := json_value_or_array_closing )

						ObjInsertAt(stack, 1, value)

						if (this.keys)
							this.keys[value] := []

					} else {
						if (ch == quot) {
							i := pos
							while (i := InStr(text, quot,, i+1)) {
								value := StrReplace(SubStr(text, pos+1, i-pos-1), "\\", "\u005c")

								static tail := A_AhkVersion<"2" ? 0 : -1
								if (SubStr(value, tail) != "\")
									break
							}

							if (!i)
								this.ParseError("'", text, pos)

							  value := StrReplace(value,  "\/",  "/")
							, value := StrReplace(value, bashq, quot)
							, value := StrReplace(value,  "\b", "`b")
							, value := StrReplace(value,  "\f", "`f")
							, value := StrReplace(value,  "\n", "`n")
							, value := StrReplace(value,  "\r", "`r")
							, value := StrReplace(value,  "\t", "`t")

							pos := i ; update pos

							i := 0
							while (i := InStr(value, "\",, i+1)) {
								if !(SubStr(value, i+1, 1) == "u")
									this.ParseError("\", text, pos - StrLen(SubStr(value, i+1)))

								uffff := Abs("0x" . SubStr(value, i+2, 4))
								if (A_IsUnicode || uffff < 0x100)
									value := SubStr(value, 1, i-1) . Chr(uffff) . SubStr(value, i+6)
							}

							if (is_key) {
								key := value, next := ":"
								continue
							}

						} else {
							value := SubStr(text, pos, i := RegExMatch(text, "[\]\},\s]|$",, pos)-pos)

							static number := "number", integer :="integer"
							if value is %number%
							{
								if value is %integer%
									value += 0
							}
							else if (value == "true" || value == "false")
								value := %value% + 0
							else if (value == "null")
								value := ""
							else
							; we can do more here to pinpoint the actual culprit
							; but that's just too much extra work.
								this.ParseError(next, text, pos, i)

							pos += i-1
						}

						next := holder==root ? "" : is_array ? ",]" : ",}"
					} ; If InStr("{[", ch) { ... } else

					is_array? key := ObjPush(holder, value) : holder[key] := value

					if (this.keys && this.keys.HasKey(holder))
						this.keys[holder].Push(key)
				}

			} ; while ( ... )

			return this.rev ? this.Walk(root, "") : root[""]
		}

		ParseError(expect, ByRef text, pos, len:=1)
		{
			static quot := Chr(34), qurly := quot . "}"

			line := StrSplit(SubStr(text, 1, pos), "`n", "`r").Length()
			col := pos - InStr(text, "`n",, -(StrLen(text)-pos+1))
			msg := Format("{1}`n`nLine:`t{2}`nCol:`t{3}`nChar:`t{4}"
			,     (expect == "")     ? "Extra data"
			    : (expect == "'")    ? "Unterminated string starting at"
			    : (expect == "\")    ? "Invalid \escape"
			    : (expect == ":")    ? "Expecting ':' delimiter"
			    : (expect == quot)   ? "Expecting object key enclosed in double quotes"
			    : (expect == qurly)  ? "Expecting object key enclosed in double quotes or object closing '}'"
			    : (expect == ",}")   ? "Expecting ',' delimiter or object closing '}'"
			    : (expect == ",]")   ? "Expecting ',' delimiter or array closing ']'"
			    : InStr(expect, "]") ? "Expecting JSON value or array closing ']'"
			    :                      "Expecting JSON value(string, number, true, false, null, object or array)"
			, line, col, pos)

			static offset := A_AhkVersion<"2" ? -3 : -4
			throw Exception(msg, offset, SubStr(text, pos, len))
		}

		Walk(holder, key)
		{
			value := holder[key]
			if IsObject(value) {
				for i, k in this.keys[value] {
					; check if ObjHasKey(value, k) ??
					v := this.Walk(value, k)
					if (v != JSON.Undefined)
						value[k] := v
					else
						ObjDelete(value, k)
				}
			}

			return this.rev.Call(holder, key, value)
		}
	}

	/**
	 * Method: Dump
	 *     Converts an AHK value into a JSON string
	 * Syntax:
	 *     str := JSON.Dump( value [, replacer, space ] )
	 * Parameter(s):
	 *     str        [retval] - JSON representation of an AHK value
	 *     value          [in] - any value(object, string, number)
	 *     replacer  [in, opt] - function object, similar to JavaScript's
	 *                           JSON.stringify() 'replacer' parameter
	 *     space     [in, opt] - similar to JavaScript's JSON.stringify()
	 *                           'space' parameter
	 */
	class Dump extends JSON.Functor
	{
		Call(self, value, replacer:="", space:="")
		{
			this.rep := IsObject(replacer) ? replacer : ""

			this.gap := ""
			if (space) {
				static integer := "integer"
				if space is %integer%
					Loop, % ((n := Abs(space))>10 ? 10 : n)
						this.gap .= " "
				else
					this.gap := SubStr(space, 1, 10)

				this.indent := "`n"
			}

			return this.Str({"": value}, "")
		}

		Str(holder, key)
		{
			value := holder[key]

			if (this.rep)
				value := this.rep.Call(holder, key, ObjHasKey(holder, key) ? value : JSON.Undefined)

			if IsObject(value) {
			; Check object type, skip serialization for other object types such as
			; ComObject, Func, BoundFunc, FileObject, RegExMatchObject, Property, etc.
				static type := A_AhkVersion<"2" ? "" : Func("Type")
				if (type ? type.Call(value) == "Object" : ObjGetCapacity(value) != "") {
					if (this.gap) {
						stepback := this.indent
						this.indent .= this.gap
					}

					is_array := value.IsArray
				; Array() is not overridden, rollback to old method of
				; identifying array-like objects. Due to the use of a for-loop
				; sparse arrays such as '[1,,3]' are detected as objects({}).
					if (!is_array) {
						for i in value
							is_array := i == A_Index
						until !is_array
					}

					str := ""
					if (is_array) {
						Loop, % value.Length() {
							if (this.gap)
								str .= this.indent

							v := this.Str(value, A_Index)
							str .= (v != "") ? v . "," : "null,"
						}
					} else {
						colon := this.gap ? ": " : ":"
						for k in value {
							v := this.Str(value, k)
							if (v != "") {
								if (this.gap)
									str .= this.indent

								str .= this.Quote(k) . colon . v . ","
							}
						}
					}

					if (str != "") {
						str := RTrim(str, ",")
						if (this.gap)
							str .= stepback
					}

					if (this.gap)
						this.indent := stepback

					return is_array ? "[" . str . "]" : "{" . str . "}"
				}

			} else ; is_number ? value : "value"
				return ObjGetCapacity([value], 1)=="" ? value : this.Quote(value)
		}

		Quote(string)
		{
			static quot := Chr(34), bashq := "\" . quot

			if (string != "") {
				  string := StrReplace(string,  "\",  "\\")
				; , string := StrReplace(string,  "/",  "\/") ; optional in ECMAScript
				, string := StrReplace(string, quot, bashq)
				, string := StrReplace(string, "`b",  "\b")
				, string := StrReplace(string, "`f",  "\f")
				, string := StrReplace(string, "`n",  "\n")
				, string := StrReplace(string, "`r",  "\r")
				, string := StrReplace(string, "`t",  "\t")

				static rx_escapable := A_AhkVersion<"2" ? "O)[^\x20-\x7e]" : "[^\x20-\x7e]"
				while RegExMatch(string, rx_escapable, m)
					string := StrReplace(string, m.Value, Format("\u{1:04x}", Ord(m.Value)))
			}

			return quot . string . quot
		}
	}

	/**
	 * Property: Undefined
	 *     Proxy for 'undefined' type
	 * Syntax:
	 *     undefined := JSON.Undefined
	 * Remarks:
	 *     For use with reviver and replacer functions since AutoHotkey does not
	 *     have an 'undefined' type. Returning blank("") or 0 won't work since these
	 *     can't be distnguished from actual JSON values. This leaves us with objects.
	 *     Replacer() - the caller may return a non-serializable AHK objects such as
	 *     ComObject, Func, BoundFunc, FileObject, RegExMatchObject, and Property to
	 *     mimic the behavior of returning 'undefined' in JavaScript but for the sake
	 *     of code readability and convenience, it's better to do 'return JSON.Undefined'.
	 *     Internally, the property returns a ComObject with the variant type of VT_EMPTY.
	 */
	Undefined[]
	{
		get {
			static empty := {}, vt_empty := ComObject(0, &empty, 1)
			return vt_empty
		}
	}

	class Functor
	{
		__Call(method, ByRef arg, args*)
		{
		; When casting to Call(), use a new instance of the "function object"
		; so as to avoid directly storing the properties(used across sub-methods)
		; into the "function object" itself.
			if IsObject(method)
				return (new this).Call(method, arg, args*)
			else if (method == "")
				return (new this).Call(arg, args*)
		}
	}
}